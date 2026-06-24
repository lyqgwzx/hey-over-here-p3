extends Node3D
# =====================================================================================
#  "Hey, Over Here!" — Godot 4.6 port of the voice-summoned office-robot HCI study.
#  Everything (3D office, robot, first-person camera, spatial audio, the 6-scenario
#  study, surveys, CSV export + local persistence) is built in code from this one script.
# =====================================================================================

# ---------- study spec (matches the web build) ----------
const DESKS := [
	{"id":"WS1","name":"Alice","x":-5.0,"z":-3.6},
	{"id":"WS2","name":"Ben","x":0.0,"z":-3.6},
	{"id":"WS3","name":"Chloe","x":5.0,"z":-3.6},   # the participant's seat
	{"id":"WS4","name":"Dan","x":-5.0,"z":3.6},
	{"id":"WS5","name":"Eve","x":0.0,"z":3.6},
	{"id":"WS6","name":"Finn","x":5.0,"z":3.6},
]
const SEAT_ID := "WS3"
const EYE := 1.18

const C_APP := Color("b388ff")
const C_VOICE := Color("46e0c8")
const C_VISUAL := Color("5aa0ff")
const C_GREEN := Color("54e08a")
const C_BEACON_FAR := Color("ffe08a")   # pale yellow far
const C_BEACON_NEAR := Color("ff2e2e")  # bright red near

# ---------- runtime ----------
var seat: Dictionary
var camera: Camera3D
var yaw := 0.0           # 0 = facing the desk (-Z); PI = facing the aisle
var pitch := -0.05
var dragging := false

var robot: Node3D
var robot_audio: AudioStreamPlayer3D
var led_mat: StandardMaterial3D
var beacons := {}        # id -> {mat:StandardMaterial3D, light:OmniLight3D, pos:Vector3}

const SPEED := 2.4
const THINK_T := 0.7
const SERVE_T := 1.4
var r_state := "idle"
var r_t := 0.0
var queue := []
var active = null
var path := []
var path_i := 0

# ---------- study ----------
var trials := []
var participant_id := ""
var participant_name := ""
var participant_sid := ""
var condition := "visual"
var surveys_on := true
var study = null
var pending = null
var app_taps := 0
var sv := {"trust":0,"confidence":0,"effort":0,"fairness":0}

# ---------- UI refs ----------
var ui: CanvasLayer
var banner_panel: PanelContainer
var banner_label: RichTextLabel
var talk_btn: Button
var app_btn: Button
var status_label: Label
var toast_panel: PanelContainer
var toast_label: RichTextLabel
var toast_tween: Tween
var w_modal: Control
var w_name: LineEdit
var w_sid: LineEdit
var w_hint: Label
var s_modal: Control
var s_meta: Label
var s_rows := {}         # key -> {buttons:Array}
var s_fair_row: Control
var d_modal: Control
var d_who: Label
var app_modal: Control
var app_body: VBoxContainer
var app_step: Label
var res_label: Label

const SAVE_PATH := "user://hoh_trials.json"

func deskById(id) -> Dictionary:
	for d in DESKS:
		if d.id == id: return d
	return {}

# =====================================================================================
func _ready() -> void:
	randomize()
	get_window().mode = Window.MODE_MAXIMIZED
	seat = deskById(SEAT_ID)
	_load_trials()
	_build_world()
	_build_ui()
	_refresh_res()
	var args := OS.get_cmdline_user_args()
	var allargs := OS.get_cmdline_args()
	if "selftest" in args or "selftest" in allargs:
		_run_selftest()
		return
	if "navtest" in args or "navtest" in allargs:
		_run_navtest()
		return
	_show_welcome()

func _run_navtest() -> void:
	participant_name = "navtest"; participant_id = "navtest"
	surveys_on = false
	condition = "voice"
	study = {"seq": [{"cond":"voice","ssl":"correct"}], "i": 0, "fair": false, "cur_ssl": "correct"}
	await get_tree().process_frame
	summon_participant()
	var t0 := _now()
	while trials.size() < 1 and _now() - t0 < 8.0:
		await get_tree().process_frame
	print("NAVTEST_OK trials=%d state=%s robot_z=%.2f" % [trials.size(), r_state, robot.position.z])
	get_tree().quit()

# =====================================================================================
#  WORLD
# =====================================================================================
func _mat(col: Color, rough := 0.8, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m

func _box(size: Vector3, pos: Vector3, col: Color, parent: Node3D = null, rough := 0.85) -> MeshInstance3D:
	if parent == null: parent = self
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(col, rough)
	mi.position = pos
	parent.add_child(mi)
	return mi

func _cyl(rt: float, rb: float, h: float, pos: Vector3, col: Color, parent: Node3D = null) -> MeshInstance3D:
	if parent == null: parent = self
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new(); cm.top_radius = rt; cm.bottom_radius = rb; cm.height = h
	mi.mesh = cm
	mi.material_override = _mat(col, 0.6)
	mi.position = pos
	parent.add_child(mi)
	return mi

func _build_world() -> void:
	# environment / lighting (bright daylight office)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.871, 0.913, 0.957)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.83, 0.9)
	env.ambient_light_energy = 1.4
	we.environment = env
	add_child(we)

	var key := DirectionalLight3D.new()
	key.light_energy = 1.6
	key.rotation = Vector3(deg_to_rad(-55), deg_to_rad(40), 0)
	key.shadow_enabled = true
	add_child(key)

	# floor
	var floor := _box(Vector3(16, 0.1, 11), Vector3(0, -0.05, 0), Color("d3dae8"))
	# walls
	var wallc := Color("eef1f7")
	_box(Vector3(16, 3.2, 0.3), Vector3(0, 1.6, -5.5), wallc)
	_box(Vector3(16, 3.2, 0.3), Vector3(0, 1.6, 5.5), wallc)
	_box(Vector3(0.3, 3.2, 11), Vector3(-8, 1.6, 0), wallc)
	_box(Vector3(0.3, 3.2, 11), Vector3(8, 1.6, 0), wallc)
	# central aisle runner
	_box(Vector3(15.6, 0.02, 2.6), Vector3(0, 0.011, 0), Color("8ccabf"))

	# cubicle side partitions (between columns), aisle gap |z|<1.6
	var partc := Color("c8d2de")
	for px in [-2.5, 2.5]:
		_box(Vector3(0.14, 1.65, 3.8), Vector3(px, 0.825, -3.5), partc)   # top band
		_box(Vector3(0.14, 1.65, 3.8), Vector3(px, 0.825, 3.5), partc)    # bottom band
	# front walls with a doorway at each desk
	var cubes := [{"x0":-8.0,"x1":-2.5,"dx":-5.0},{"x0":-2.5,"x1":2.5,"dx":0.0},{"x0":2.5,"x1":8.0,"dx":5.0}]
	for fz in [-1.6, 1.6]:
		for c in cubes:
			var gl: float = c.dx - 0.75
			var gr: float = c.dx + 0.75
			if gl > c.x0 + 0.05:
				_box(Vector3(gl - c.x0, 1.65, 0.14), Vector3((c.x0 + gl) / 2.0, 0.825, fz), partc)
			if gr < c.x1 - 0.05:
				_box(Vector3(c.x1 - gr, 1.65, 0.14), Vector3((gr + c.x1) / 2.0, 0.825, fz), partc)

	# desks + stools + beacons + labels
	for d in DESKS:
		_build_desk(d)

	# dock pad
	_cyl(0.55, 0.55, 0.04, Vector3(0, 0.02, 0), Color("10271f"))

	# robot
	_build_robot()

	# first-person camera at the seat
	camera = Camera3D.new()
	camera.position = Vector3(seat.x, EYE, seat.z + 0.5)
	camera.fov = 62
	add_child(camera)
	camera.current = true
	var listener := AudioListener3D.new()
	camera.add_child(listener)
	listener.make_current()
	_apply_camera()

func _build_desk(d: Dictionary) -> void:
	var g := Node3D.new()
	g.position = Vector3(d.x, 0, d.z)
	add_child(g)
	var wall_: float = -1.0 if d.z < 0 else 1.0
	# desk top + legs
	_box(Vector3(2.0, 0.08, 0.85), Vector3(0, 0.74, wall_ * 0.55), Color("d9c39c"), g, 0.6)
	for lx in [-0.85, 0.85]:
		for lz in [-0.3, 0.3]:
			_box(Vector3(0.08, 0.74, 0.08), Vector3(lx, 0.37, wall_ * 0.55 + lz), Color("c8d2de"), g)
	# monitor
	var mon := _box(Vector3(0.62, 0.4, 0.05), Vector3(0, 1.05, wall_ * 0.85), Color("0a0d16"), g)
	var mm := mon.material_override as StandardMaterial3D
	mm.emission_enabled = true; mm.emission = Color("16314a"); mm.emission_energy_multiplier = 0.6
	# stool (seat + post + foot) — not at the participant's own seat
	if d.id != SEAT_ID:
		_cyl(0.26, 0.27, 0.1, Vector3(0, 0.5, -wall_ * 0.25), Color("4fa394"), g)
		_cyl(0.045, 0.045, 0.45, Vector3(0, 0.225, -wall_ * 0.25), Color("8a97a8"), g)
		_cyl(0.21, 0.23, 0.04, Vector3(0, 0.02, -wall_ * 0.25), Color("8a97a8"), g)
		_add_label(g, d.id + " · " + d.name, Vector3(0, 1.7, wall_ * 0.6))
	# desk locate-light (beacon) on the desk
	var bx := 0.6
	var bz := wall_ * 0.2
	_cyl(0.05, 0.06, 0.06, Vector3(bx, 0.81, bz), Color("2a3346"), g)
	var orb := MeshInstance3D.new()
	var sm := SphereMesh.new(); sm.radius = 0.055; sm.height = 0.11
	orb.mesh = sm
	var omat := _mat(Color("12161f"))
	omat.emission_enabled = true; omat.emission = Color.BLACK; omat.emission_energy_multiplier = 0.0
	orb.material_override = omat
	orb.position = Vector3(bx, 0.9, bz)
	g.add_child(orb)
	var bl := OmniLight3D.new()
	bl.light_energy = 0.0
	bl.omni_range = 2.0
	bl.position = Vector3(bx, 1.0, bz)
	g.add_child(bl)
	beacons[d.id] = {"mat": omat, "light": bl}

func _add_label(parent: Node3D, text: String, pos: Vector3) -> void:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font_size = 48
	lbl.pixel_size = 0.004
	lbl.modulate = Color("1d2740")
	lbl.outline_modulate = Color(1, 1, 1, 0.9)
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.position = pos
	parent.add_child(lbl)

func _build_robot() -> void:
	robot = Node3D.new()
	robot.position = Vector3(0, 0, 0)
	add_child(robot)
	_cyl(0.34, 0.4, 0.5, Vector3(0, 0.32, 0), Color("d7deea"), robot)
	var dome := MeshInstance3D.new()
	var dm := SphereMesh.new(); dm.radius = 0.34; dm.height = 0.5; dm.is_hemisphere = true
	dome.mesh = dm
	dome.material_override = _mat(Color("0c1322"), 0.3, 0.4)
	dome.position = Vector3(0, 0.5, 0)
	robot.add_child(dome)
	# LED ring
	var led := MeshInstance3D.new()
	var tm := TorusMesh.new(); tm.inner_radius = 0.27; tm.outer_radius = 0.33
	led.mesh = tm
	led_mat = _mat(Color("222a3a"))
	led_mat.emission_enabled = true; led_mat.emission = Color.BLACK; led_mat.emission_energy_multiplier = 1.0
	led.material_override = led_mat
	led.position = Vector3(0, 0.58, 0)
	robot.add_child(led)
	# eye (facing marker)
	_box(Vector3(0.14, 0.14, 0.05), Vector3(0, 0.6, 0.3), Color("46e0c8"), robot)
	# wheels
	for wx in [-0.34, 0.34]:
		var w := _cyl(0.12, 0.12, 0.07, Vector3(wx, 0.12, 0), Color("0a0d16"), robot)
		w.rotation = Vector3(0, 0, deg_to_rad(90))
	# bin slot
	_box(Vector3(0.3, 0.18, 0.06), Vector3(0, 0.32, 0.4), Color("0a0d16"), robot)
	# spatial-audio hum
	robot_audio = AudioStreamPlayer3D.new()
	robot_audio.stream = _make_hum()
	robot_audio.max_distance = 32.0
	robot_audio.unit_size = 4.0
	robot_audio.volume_db = -60.0
	robot.add_child(robot_audio)
	robot_audio.play()

func _make_hum() -> AudioStreamWAV:
	var rate := 22050
	var n := rate / 2   # 0.5s loop
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / rate
		var s := 0.55 * sin(TAU * 60.0 * t)
		s += 0.25 * sin(TAU * 90.0 * t)
		s += 0.12 * (randf() * 2.0 - 1.0)   # wheel noise
		s = clampf(s, -1.0, 1.0) * 0.5
		data.encode_s16(i * 2, int(s * 30000))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = n - 1
	wav.data = data
	return wav

# =====================================================================================
#  CAMERA / INPUT
# =====================================================================================
func _apply_camera() -> void:
	camera.rotation = Vector3(pitch, yaw, 0)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		dragging = event.pressed
	elif event is InputEventMouseMotion and dragging:
		yaw -= event.relative.x * 0.005
		pitch = clampf(pitch - event.relative.y * 0.004, -1.05, 1.05)
		_apply_camera()
	elif event is InputEventKey and event.keycode == KEY_SPACE:
		if event.pressed and not event.echo:
			_talk_start()
		elif not event.pressed:
			_talk_end()

# =====================================================================================
#  ROBOT NAV + STATE MACHINE
# =====================================================================================
func _approach(d: Dictionary) -> Vector3:
	return Vector3(d.x, 0, -2.1 if d.z < 0 else 2.1)

func _build_path(fromp: Vector3, top: Vector3) -> Array:
	var az := clampf(fromp.z, -0.95, 0.95)
	return [Vector3(fromp.x, 0, az), Vector3(top.x, 0, az), top]

func _run_ssl(caller_id: String, mode) -> String:
	if mode == "correct": return caller_id
	if mode == "error":
		var idx := 0
		for i in DESKS.size():
			if DESKS[i].id == caller_id: idx = i
		var cand := []
		for j in [(idx + 1) % DESKS.size(), (idx + 5) % DESKS.size()]:
			if DESKS[j].id != caller_id: cand.append(DESKS[j].id)
		return cand[randi() % cand.size()]
	return caller_id

func _make_request(caller_id: String, method: String, ui_actions: int, ssl_mode, ghost := false) -> Dictionary:
	var target_id := caller_id if method == "app" else _run_ssl(caller_id, ssl_mode)
	var req := {
		"callerId": caller_id, "method": method, "uiActions": ui_actions, "targetId": target_id,
		"ghost": ghost, "sslCorrect": null if method == "app" else (target_id == caller_id),
		"tIntent": _now(), "tQueued": _now(), "tArrive": 0.0, "waited": 0.0, "queued": 0.0,
	}
	queue.append(req)
	return req

func _start_serving(req: Dictionary) -> void:
	active = req
	req.tStart = _now()
	req.queued = req.tStart - req.tQueued
	r_state = "thinking"; r_t = 0.0
	_set_led(Color("ffc24a") if req.method == "visual" else Color.BLACK)
	_set_beacon(req.targetId if req.method == "visual" else "")
	if study != null and study.fair and not req.ghost and req.callerId == seat.id and req.get("queued", 0.0) > 0.3:
		_show_toast("✅ You're up next", "Thanks for waiting — the robot is now heading to your desk.")

func _process(delta: float) -> void:
	_tick_robot(delta)
	_update_beacons(delta)
	_drive_audio(delta)
	# led pulse
	if led_mat and led_mat.emission != Color.BLACK:
		led_mat.emission_energy_multiplier = 0.7 + 0.3 * sin(Time.get_ticks_msec() * 0.006)

func _tick_robot(delta: float) -> void:
	r_t += delta
	match r_state:
		"idle":
			if active == null and queue.size() > 0:
				_start_serving(queue.pop_front())
		"thinking":
			if r_t >= THINK_T:
				path = _build_path(robot.position, _approach(deskById(active.targetId)))
				path_i = 0
				r_state = "moving"
				_set_led(Color("46e0c8") if active.method == "visual" else Color.BLACK)
		"moving":
			if _step_path(delta): _arrive()
		"serving":
			if r_t >= SERVE_T:
				_set_led(C_GREEN if active.method == "visual" else Color.BLACK)
				_finish_active()
		"returning":
			if _step_path(delta):
				r_state = "idle"; _set_led(Color.BLACK); _set_beacon("")

func _step_path(delta: float) -> bool:
	if path_i >= path.size(): return true
	var tgt: Vector3 = path[path_i]
	var to := tgt - robot.position
	var dist := to.length()
	if dist < 0.06:
		path_i += 1
		return path_i >= path.size()
	var step := minf(dist, SPEED * delta)
	robot.position += to.normalized() * step
	var desired := atan2(to.x, to.z)
	robot.rotation.y = lerp_angle(robot.rotation.y, desired, 0.18)
	return false

func _arrive() -> void:
	active.tArrive = _now()
	active.waited = active.tArrive - active.tIntent
	r_state = "serving"; r_t = 0.0

func _finish_active() -> void:
	var req = active
	active = null
	_complete_trial(req)
	path = _build_path(robot.position, Vector3(0, 0, 0))
	path_i = 0
	r_state = "returning"

func _set_led(col: Color) -> void:
	if led_mat: led_mat.emission = col

func _set_beacon(target_id: String) -> void:
	for id in beacons.keys():
		beacons[id]["active"] = (target_id != "" and id == target_id)

func _update_beacons(_delta: float) -> void:
	var now_s := Time.get_ticks_msec() / 1000.0
	for id in beacons.keys():
		var b = beacons[id]
		if not b.get("active", false):
			if b.mat.emission_energy_multiplier != 0.0:
				b.mat.emission = Color.BLACK; b.mat.emission_energy_multiplier = 0.0; b.light.light_energy = 0.0
			continue
		var d := deskById(id)
		if r_state == "serving" and active != null and active.targetId == id:
			b.mat.emission = C_BEACON_NEAR; b.mat.emission_energy_multiplier = 2.4
			b.light.light_color = C_BEACON_NEAR; b.light.light_energy = 1.8
		else:
			var ap := _approach(d)
			var dist := Vector2(robot.position.x - ap.x, robot.position.z - ap.z).length()
			var prox := clampf(1.0 - dist / 11.0, 0.0, 1.0)
			var col := C_BEACON_FAR.lerp(C_BEACON_NEAR, prox)
			var freq := 1.3 + prox * 6.5
			var pulse := 0.45 + 0.55 * (0.5 + 0.5 * sin(now_s * freq * TAU))
			b.mat.emission = col; b.mat.emission_energy_multiplier = pulse * 2.2
			b.light.light_color = col; b.light.light_energy = pulse * 1.5

func _drive_audio(delta: float) -> void:
	var target := 0.0
	if r_state == "moving": target = 0.17
	elif r_state == "thinking" or r_state == "serving": target = 0.08
	elif r_state == "returning": target = 0.13
	# convert linear 0..0.2 to volume_db; -60 when ~0
	var cur := db_to_linear(robot_audio.volume_db)
	cur += (target - cur) * minf(1.0, delta * 4.0)
	robot_audio.volume_db = -60.0 if cur < 0.001 else linear_to_db(cur)
	robot_audio.pitch_scale = 1.0 if r_state != "moving" else 1.25

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

# =====================================================================================
#  STUDY FLOW
# =====================================================================================
func _set_condition(c: String) -> void:
	condition = c
	var nm := {"app":"app baseline","voice":"voice only","visual":"voice + visual"}
	status_label.text = "condition: %s    ·    seat: %s · %s" % [nm[c], seat.id, seat.name]

func start_guided() -> void:
	var core := [
		{"cond":"app"},
		{"cond":"voice","ssl":"correct"}, {"cond":"voice","ssl":"error"},
		{"cond":"visual","ssl":"correct"}, {"cond":"visual","ssl":"error"},
	]
	core.shuffle()
	core.append({"cond":"visual","ssl":"correct","fair":true})
	study = {"seq": core, "i": 0, "fair": false, "cur_ssl": null}
	surveys_on = true
	_guided_step()

func _guided_step() -> void:
	if study == null: return
	if study.i >= study.seq.size():
		_hide_banner()
		d_who.text = "Recorded as: " + _who_label(participant_name, participant_sid)
		d_modal.visible = true
		study = null
		_refresh_res()
		return
	var item = study.seq[study.i]
	_set_condition(item.cond)
	study.cur_ssl = item.get("ssl", null)
	study.fair = item.get("fair", false)
	var what := ""
	var instr := ""
	if study.fair:
		what = "[b]Rush hour.[/b] A colleague across the room calls the robot at the same moment."
		instr = "🎙 Hold the button (or Space) and say “over here”."
	elif item.cond == "app":
		what = "[b]There's a snack wrapper on your desk.[/b] Summon the cleaning robot with its phone app."
		instr = "📱 Open the app → Menu → pick your desk → Summon."
	elif item.cond == "voice":
		what = "[b]Your hands are full[/b], so you just call out. No lights, no screen."
		instr = "🎙 Hold the button (or Space) and say “over here”."
	else:
		what = "[b]You call it by voice[/b] — this robot lights up and your desk lamp signals when it locks onto you."
		instr = "🎙 Hold the button (or Space) and say “over here”."
	_show_banner("Scenario %d of %d\n%s\n%s" % [study.i + 1, study.seq.size(), what, instr])
	talk_btn.visible = item.cond != "app"
	app_btn.visible = item.cond == "app"
	talk_btn.disabled = false; app_btn.disabled = false
	if study.fair:
		await get_tree().create_timer(1.0).timeout
		if study != null and study.fair:
			var o = null
			for d in DESKS:
				if d.id != seat.id: o = d; break
			if o: _make_request(o.id, "visual", 1, "correct", true)

func summon_participant() -> void:
	if study == null and not explore_mode: return        # not started yet — ignore stray summons
	if study != null and study.i >= study.seq.size(): return
	var method := condition
	var taps := app_taps if method == "app" else 1
	_make_request(seat.id, method, taps, study.cur_ssl if study else null, false)
	if study != null and study.fair and active != null and active.callerId != seat.id:
		var colleague := deskById(active.callerId)
		_show_toast("🔔 Robot is busy right now", "Serving %s first — you're next in line.\nETA ~%d s" % [colleague.name, _estimate_eta()])
	talk_btn.disabled = true; app_btn.disabled = true

func _complete_trial(req: Dictionary) -> void:
	if req.ghost: return
	var fair: bool = study != null and study.fair
	var rec := {
		"n": trials.size() + 1, "step": (study.i + 1) if study else 0,
		"participant": participant_id if participant_id != "" else "anon",
		"name": participant_name, "sid": participant_sid, "seat": seat.name,
		"condition": req.method, "caller": deskById(req.callerId).name,
		"target": deskById(req.targetId).name, "arrival": req.waited, "actions": req.uiActions,
		"sslCorrect": req.sslCorrect, "wait": req.get("queued", 0.0), "fair": fair,
		"at": Time.get_datetime_string_from_system(true),
		"trust": null, "confidence": null, "effort": null, "fairness": null,
	}
	trials.append(rec)
	_save_trials()
	_refresh_res()
	if surveys_on:
		pending = rec
		await get_tree().create_timer(2.9).timeout
		if pending == rec: _open_survey(rec)
	elif study != null:
		study.i += 1
		await get_tree().create_timer(0.7).timeout
		_guided_step()

# =====================================================================================
#  SELFTEST (headless validation): run one scripted participant, export, quit.
# =====================================================================================
func _run_selftest() -> void:
	participant_name = "selftest"; participant_sid = "0000"; participant_id = "0000"
	surveys_on = false
	var seq := [
		{"cond":"app","ssl":null},{"cond":"voice","ssl":"correct"},{"cond":"voice","ssl":"error"},
		{"cond":"visual","ssl":"correct"},{"cond":"visual","ssl":"error"},{"cond":"visual","ssl":"correct","fair":true},
	]
	for item in seq:
		var caller = seat.id
		var target = caller if item.cond == "app" else _run_ssl(caller, item.get("ssl"))
		var rec := {
			"n": trials.size() + 1, "step": trials.size() + 1, "participant": "0000",
			"name": "selftest", "sid": "0000", "seat": seat.name, "condition": item.cond,
			"caller": deskById(caller).name, "target": deskById(target).name,
			"arrival": 3.0, "actions": 2 if item.cond == "app" else 1,
			"sslCorrect": null if item.cond == "app" else (target == caller),
			"wait": 1.0 if item.get("fair", false) else 0.0, "fair": item.get("fair", false),
			"at": Time.get_datetime_string_from_system(true),
			"trust": randi_range(3, 5), "confidence": randi_range(2, 5),
			"effort": randi_range(1, 3), "fairness": randi_range(3, 5) if item.get("fair", false) else null,
		}
		trials.append(rec)
	_save_trials()
	var p := export_csv()
	print("SELFTEST_OK trials=%d csv=%s" % [trials.size(), p])
	get_tree().quit()

# =====================================================================================
#  CSV + PERSISTENCE
# =====================================================================================
func _who_label(nm: String, sid: String) -> String:
	if nm != "" and sid != "": return nm + " · " + sid
	return nm if nm != "" else (sid if sid != "" else "anon")

func _csv_cell(v) -> String:
	var s := str(v)
	if s.contains(",") or s.contains("\"") or s.contains("\n"):
		return "\"" + s.replace("\"", "\"\"") + "\""
	return s

func export_csv() -> String:
	var head := ["participant_id","participant_name","student_id","trial","step","seat","condition",
		"is_multiuser","caller","target_desk","localization_ok","time_to_arrival_s","ui_actions",
		"queue_wait_s","trust_1to5","confidence_1to5","effort_1to5","fairness_1to5","timestamp"]
	var lines := [",".join(head)]
	for r in trials:
		var loc: String = "" if r.sslCorrect == null else ("1" if r.sslCorrect else "0")
		var row := [r.participant, r.name, r.sid, r.n, r.step, r.seat, r.condition,
			(1 if r.fair else 0), r.caller, r.target, loc,
			"%.2f" % r.arrival, r.actions, "%.2f" % r.get("wait", 0.0),
			_nz(r.trust), _nz(r.confidence), _nz(r.effort), _nz(r.fairness), r.at]
		var cells := []
		for c in row: cells.append(_csv_cell(c))
		lines.append(",".join(cells))
	var path := "user://hey_over_here_godot.csv"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("\n".join(lines))
	f.close()
	return ProjectSettings.globalize_path(path)

func _nz(v) -> String:
	return "" if v == null else str(v)

func _save_trials() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(trials))
		f.close()

func _load_trials() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if f:
			var data = JSON.parse_string(f.get_as_text())
			f.close()
			if data is Array: trials = data

# =====================================================================================
#  UI  (built in code on a CanvasLayer)
# =====================================================================================
func _theme_font(c: Control, size: int) -> void:
	c.add_theme_font_size_override("font_size", size)

func _panel_box(col := Color("161d2e")) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(20)
	return sb

func _mk_button(text: String, col := Color("1d2740")) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 40)
	_theme_font(b, 15)
	return b

func _modal_root() -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.04, 0.08, 0.42)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)
	ui.add_child(root)
	root.visible = false
	return root

func _centered_panel(root: Control, width := 540) -> VBoxContainer:
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(cc)
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", _panel_box())
	pc.custom_minimum_size = Vector2(width, 0)
	cc.add_child(pc)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	pc.add_child(vb)
	return vb

func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)

	# status (top-right)
	status_label = Label.new()
	status_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	status_label.position = Vector2(-360, 12); status_label.size = Vector2(348, 24)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_theme_font(status_label, 13); status_label.modulate = Color("93a0bd")
	ui.add_child(status_label)

	# macOS-style notification toast (top-right)
	toast_panel = PanelContainer.new()
	var tbox := _panel_box(Color(0.10, 0.13, 0.19, 0.97))
	tbox.set_corner_radius_all(16)
	tbox.border_width_left = 1; tbox.border_width_top = 1
	tbox.border_width_right = 1; tbox.border_width_bottom = 1
	tbox.border_color = Color(1, 1, 1, 0.10)
	tbox.shadow_size = 12; tbox.shadow_color = Color(0, 0, 0, 0.38)
	toast_panel.add_theme_stylebox_override("panel", tbox)
	toast_panel.custom_minimum_size = Vector2(340, 0)
	toast_label = RichTextLabel.new()
	toast_label.bbcode_enabled = true; toast_label.fit_content = true
	toast_label.custom_minimum_size = Vector2(308, 0)
	toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_theme_font(toast_label, 14)
	toast_panel.add_child(toast_label)
	ui.add_child(toast_panel)
	toast_panel.visible = false

	# banner (top centre)
	banner_panel = PanelContainer.new()
	banner_panel.add_theme_stylebox_override("panel", _panel_box(Color(0.08, 0.12, 0.2, 0.92)))
	banner_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	banner_panel.position = Vector2(-430, 16); banner_panel.custom_minimum_size = Vector2(860, 0)
	banner_label = RichTextLabel.new()
	banner_label.bbcode_enabled = true
	banner_label.fit_content = true
	banner_label.custom_minimum_size = Vector2(820, 0)
	banner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_theme_font(banner_label, 15)
	banner_panel.add_child(banner_label)
	ui.add_child(banner_panel)
	banner_panel.visible = false

	# talk button (bottom centre)
	talk_btn = _mk_button("🎙 Hold to summon (\"over here\")")
	talk_btn.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	talk_btn.position = Vector2(-150, -70); talk_btn.custom_minimum_size = Vector2(300, 52)
	talk_btn.button_down.connect(_talk_start)
	talk_btn.button_up.connect(_talk_end)
	ui.add_child(talk_btn)
	talk_btn.visible = false

	app_btn = _mk_button("📱 Open app")
	app_btn.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	app_btn.position = Vector2(-90, -70); app_btn.custom_minimum_size = Vector2(180, 52)
	app_btn.pressed.connect(_open_app)
	ui.add_child(app_btn)
	app_btn.visible = false

	# researcher export (bottom-left)
	var res_box := VBoxContainer.new()
	res_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	res_box.position = Vector2(12, -64)
	res_label = Label.new(); _theme_font(res_label, 12); res_label.modulate = Color("93a0bd")
	res_box.add_child(res_label)
	var csv_btn := _mk_button("⬇ Export CSV")
	csv_btn.pressed.connect(_on_export)
	res_box.add_child(csv_btn)
	ui.add_child(res_box)

	_build_welcome()
	_build_survey()
	_build_done()
	_build_app_modal()

func _build_welcome() -> void:
	w_modal = _modal_root()
	var vb := _centered_panel(w_modal, 520)
	var t := Label.new(); t.text = "Help test a voice-summoned office robot"; _theme_font(t, 21); vb.add_child(t)
	var p := Label.new(); p.text = "You're seated at your desk. Call a cleaning robot over a few times — by app or by saying \"over here\" — and rate each. Use headphones. No right or wrong answers. ~4 min."
	p.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; p.custom_minimum_size = Vector2(480, 0); _theme_font(p, 14); p.modulate = Color("c4cde0"); vb.add_child(p)
	var hb := HBoxContainer.new(); hb.add_theme_constant_override("separation", 10); vb.add_child(hb)
	var nv := VBoxContainer.new(); hb.add_child(nv)
	var nl := Label.new(); nl.text = "Name"; _theme_font(nl, 13); nv.add_child(nl)
	w_name = LineEdit.new(); w_name.placeholder_text = "e.g. Alex"; w_name.custom_minimum_size = Vector2(230, 36); nv.add_child(w_name)
	var sv2 := VBoxContainer.new(); hb.add_child(sv2)
	var sl := Label.new(); sl.text = "Student ID"; _theme_font(sl, 13); sv2.add_child(sl)
	w_sid = LineEdit.new(); w_sid.placeholder_text = "e.g. 12345678"; w_sid.custom_minimum_size = Vector2(230, 36); sv2.add_child(w_sid)
	w_hint = Label.new(); w_hint.text = "Fill in at least one — name or student ID."; _theme_font(w_hint, 12); w_hint.modulate = Color("93a0bd"); vb.add_child(w_hint)
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 10); vb.add_child(row)
	var begin := _mk_button("▶ Begin the experiment"); begin.pressed.connect(_begin_guided); row.add_child(begin)

func _build_survey() -> void:
	s_modal = _modal_root()
	var vb := _centered_panel(s_modal, 560)
	var t := Label.new(); t.text = "Quick rating"; _theme_font(t, 20); vb.add_child(t)
	s_meta = Label.new(); _theme_font(s_meta, 12); s_meta.modulate = Color("93a0bd"); vb.add_child(s_meta)
	_likert_row(vb, "trust", "★ Main · I always knew where the robot was going — never confused.", "1 couldn't tell", "5 always knew")
	_likert_row(vb, "confidence", "I trusted it to come to the right desk.", "1 not confident", "5 fully trusted")
	_likert_row(vb, "effort", "How mentally demanding was this summon?", "1 effortless", "5 exhausting")
	s_fair_row = _likert_row(vb, "fairness", "It handled everyone fairly — acknowledged, queued, gave an ETA.", "1 very unfair", "5 very fair")
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 10); vb.add_child(row)
	var sub := _mk_button("Submit rating"); sub.pressed.connect(_survey_submit); row.add_child(sub)
	var skip := _mk_button("Skip"); skip.pressed.connect(_survey_skip); row.add_child(skip)

func _likert_row(vb: VBoxContainer, key: String, q: String, lo: String, hi: String) -> Control:
	var wrap := VBoxContainer.new(); vb.add_child(wrap)
	var ql := Label.new(); ql.text = q; ql.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; ql.custom_minimum_size = Vector2(520, 0); _theme_font(ql, 14); wrap.add_child(ql)
	var hb := HBoxContainer.new(); hb.add_theme_constant_override("separation", 6); wrap.add_child(hb)
	var btns := []
	for i in range(1, 6):
		var b := _mk_button(str(i)); b.custom_minimum_size = Vector2(96, 38)
		var val := i
		b.pressed.connect(func(): _pick_likert(key, val))
		hb.add_child(b); btns.append(b)
	var ends := HBoxContainer.new(); wrap.add_child(ends)
	var le := Label.new(); le.text = lo; _theme_font(le, 11); le.modulate = Color("93a0bd"); le.custom_minimum_size = Vector2(250, 0); ends.add_child(le)
	var he := Label.new(); he.text = hi; _theme_font(he, 11); he.modulate = Color("93a0bd"); he.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; he.custom_minimum_size = Vector2(250, 0); ends.add_child(he)
	s_rows[key] = btns
	return wrap

func _pick_likert(key: String, val: int) -> void:
	sv[key] = val
	var btns = s_rows[key]
	for i in btns.size():
		btns[i].modulate = Color("46e0c8") if (i + 1) == val else Color.WHITE

func _build_done() -> void:
	d_modal = _modal_root()
	var vb := _centered_panel(d_modal, 480)
	var t := Label.new(); t.text = "✓ All done — thank you!"; _theme_font(t, 21); vb.add_child(t)
	var p := Label.new(); p.text = "That's the whole study — your answers are saved."; _theme_font(p, 14); p.modulate = Color("c4cde0"); vb.add_child(p)
	d_who = Label.new(); _theme_font(d_who, 13); d_who.modulate = Color("8fe3c8"); vb.add_child(d_who)
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 10); vb.add_child(row)
	var nxt := _mk_button("▶ Next participant"); nxt.pressed.connect(_done_next); row.add_child(nxt)
	var cls := _mk_button("Close"); cls.pressed.connect(func(): d_modal.visible = false); row.add_child(cls)

func _build_app_modal() -> void:
	app_modal = _modal_root()
	var vb := _centered_panel(app_modal, 320)
	var t := Label.new(); t.text = "🗑 BinBot App"; _theme_font(t, 18); vb.add_child(t)
	app_step = Label.new(); _theme_font(app_step, 12); app_step.modulate = Color("93a0bd"); vb.add_child(app_step)
	app_body = VBoxContainer.new(); app_body.add_theme_constant_override("separation", 8); vb.add_child(app_body)

# ---------- UI flow ----------
func _show_welcome() -> void:
	w_name.text = ""; w_sid.text = ""
	w_hint.text = "Fill in at least one — name or student ID."; w_hint.modulate = Color("93a0bd")
	w_modal.visible = true

func _begin_guided() -> void:
	var nm := w_name.text.strip_edges()
	var sid := w_sid.text.strip_edges()
	if nm == "" and sid == "":
		w_hint.text = "Please fill in at least one — name or student ID."; w_hint.modulate = Color("ff8a8a")
		return
	participant_name = nm; participant_sid = sid; participant_id = sid if sid != "" else nm
	w_modal.visible = false
	start_guided()

func _skip_explore() -> void:
	w_modal.visible = false
	surveys_on = false
	explore_mode = true
	_set_condition("visual")
	talk_btn.visible = true; app_btn.visible = true
	_show_banner("Explore mode\nDrag to look · hold the button or Space to summon · listen for the robot.")
	await get_tree().create_timer(6.0).timeout
	_hide_banner()

var talking := false
var explore_mode := false
func _talk_start() -> void:
	if not talk_btn.visible or talk_btn.disabled: return
	if w_modal.visible or s_modal.visible or d_modal.visible or app_modal.visible: return
	talking = true; talk_btn.text = "● Listening… release to summon"

func _talk_end() -> void:
	if not talking: return
	talking = false; talk_btn.text = "🎙 Hold to summon (\"over here\")"
	summon_participant()

func _open_app() -> void:
	app_taps = 0
	app_modal.visible = true
	_app_menu()

func _app_menu() -> void:
	app_step.text = "Step 1 — open menu"
	for c in app_body.get_children(): c.queue_free()
	var b := _mk_button("☰ Menu ▾"); b.pressed.connect(func(): app_taps += 1; _app_list()); app_body.add_child(b)

func _app_list() -> void:
	app_step.text = "Step 2 — pick your desk"
	for c in app_body.get_children(): c.queue_free()
	for d in DESKS:
		var lbl: String = d.id + " · " + d.name + ("  (you)" if d.id == seat.id else "")
		var b := _mk_button(lbl)
		var dd = d
		b.pressed.connect(func(): app_taps += 1; _app_confirm(dd))
		app_body.add_child(b)

func _app_confirm(d: Dictionary) -> void:
	app_step.text = "Step 3 — confirm"
	for c in app_body.get_children(): c.queue_free()
	var b := _mk_button("✓ Summon to " + d.id + " · " + d.name)
	b.pressed.connect(func():
		app_taps += 1
		app_modal.visible = false
		condition = "app"
		_make_request(seat.id, "app", app_taps, null, false)
		app_btn.disabled = true)
	app_body.add_child(b)

func _open_survey(rec: Dictionary) -> void:
	sv = {"trust":0,"confidence":0,"effort":0,"fairness":0}
	for key in s_rows.keys():
		for b in s_rows[key]: b.modulate = Color.WHITE
	s_fair_row.visible = rec.fair
	s_meta.text = "Condition: %s · caller: %s · arrived in %.1fs" % [rec.condition, rec.caller, rec.arrival]
	s_modal.visible = true

func _survey_submit() -> void:
	if pending != null:
		pending.trust = sv.trust if sv.trust > 0 else null
		pending.confidence = sv.confidence if sv.confidence > 0 else null
		pending.effort = sv.effort if sv.effort > 0 else null
		pending.fairness = (sv.fairness if sv.fairness > 0 else null) if pending.fair else null
		_save_trials(); _refresh_res()
	pending = null
	_close_survey_advance()

func _survey_skip() -> void:
	pending = null
	_close_survey_advance()

func _close_survey_advance() -> void:
	s_modal.visible = false
	if study != null:
		study.i += 1
		await get_tree().create_timer(0.5).timeout
		_guided_step()

func _done_next() -> void:
	d_modal.visible = false
	_show_welcome()

func _show_banner(text: String) -> void:
	banner_label.text = text
	banner_panel.visible = true

func _hide_banner() -> void:
	banner_panel.visible = false

func _show_toast(title: String, body: String, dur := 4.2) -> void:
	if toast_panel == null: return
	toast_label.text = "[b]%s[/b]\n%s" % [title, body]
	toast_panel.visible = true
	toast_panel.modulate.a = 0.0
	var rest_x := get_viewport().get_visible_rect().size.x - 364.0
	toast_panel.position = Vector2(rest_x + 70.0, 48.0)
	if toast_tween and toast_tween.is_valid(): toast_tween.kill()
	toast_tween = create_tween()
	toast_tween.tween_property(toast_panel, "modulate:a", 1.0, 0.28)
	toast_tween.parallel().tween_property(toast_panel, "position:x", rest_x, 0.36).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	toast_tween.tween_interval(dur)
	toast_tween.tween_property(toast_panel, "modulate:a", 0.0, 0.32)
	toast_tween.parallel().tween_property(toast_panel, "position:x", rest_x + 70.0, 0.32)
	toast_tween.tween_callback(func(): toast_panel.visible = false)

func _estimate_eta() -> int:
	var my_target := _approach(seat)
	var secs := 0.0
	if active != null:
		var col_target := _approach(deskById(active.targetId))
		secs += robot.position.distance_to(col_target) / SPEED + SERVE_T
		secs += THINK_T + col_target.distance_to(my_target) / SPEED + SERVE_T
	else:
		secs += THINK_T + robot.position.distance_to(my_target) / SPEED + SERVE_T
	return int(round(maxf(secs, 3.0)))

func _refresh_res() -> void:
	var parts := {}
	for t in trials: parts[t.participant] = true
	if res_label:
		res_label.text = "%d trials · %d participant(s)" % [trials.size(), parts.size()] if trials.size() > 0 else "No data yet."

func _on_export() -> void:
	var p := export_csv()
	res_label.text = "Exported %d trials →\n%s" % [trials.size(), p]
	print("CSV exported: ", p)
