/**
 * "Hey, Over Here!" — remote data collector (Google Apps Script)
 * Appends each rated trial POSTed by the simulation into a Google Sheet.
 *
 * ── HOW TO DEPLOY (one time, ~3 min, needs your Google account) ──────────────
 * 1. Open  https://sheets.new  → name it e.g. "HeyOverHere Data".
 * 2. Extensions → Apps Script.
 * 3. Delete the sample code, paste EVERYTHING in this file, click Save (disk icon).
 * 4. Deploy → New deployment → gear icon → "Web app".
 *      - Description: anything
 *      - Execute as:  Me
 *      - Who has access:  Anyone        ← important
 *    Deploy → Authorize access (allow your own account).
 * 5. Copy the "Web app URL" (ends with /exec).
 * 6. Send me that URL — I paste it into the simulation (DATA_ENDPOINT) and push.
 *
 * Test it: open the /exec URL in a browser → you should see {"ok":true,"info":"..."} .
 * Every finished trial then auto-adds a row to the "data" sheet.
 */

function doPost(e) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);                       // avoid races when several participants submit at once
    var ss = SpreadsheetApp.getActiveSpreadsheet();
    var sheet = ss.getSheetByName('data') || ss.insertSheet('data');
    if (sheet.getLastRow() === 0) {
      sheet.appendRow(['participant_id','trial','condition','caller','target_desk',
        'time_to_arrival_s','ui_actions','ssl_correct','queue_wait_s','trust_1to5','effort_1to5','submitted_at']);
    }
    var d = JSON.parse(e.postData.contents);
    var rows = d.trials || (d.trial ? [d.trial] : []);
    var ts = d.submittedAt || new Date().toISOString();
    rows.forEach(function (t) {
      sheet.appendRow([
        d.participant, t.n, t.condition, t.caller, t.target,
        t.arrival, t.actions,
        (t.sslCorrect === null || t.sslCorrect === undefined) ? '' : (t.sslCorrect ? 1 : 0),
        t.wait,
        (t.trust === null || t.trust === undefined) ? '' : t.trust,
        (t.effort === null || t.effort === undefined) ? '' : t.effort,
        ts
      ]);
    });
    return ContentService.createTextOutput(JSON.stringify({ ok: true, rows: rows.length }))
      .setMimeType(ContentService.MimeType.JSON);
  } catch (err) {
    return ContentService.createTextOutput(JSON.stringify({ ok: false, error: String(err) }))
      .setMimeType(ContentService.MimeType.JSON);
  } finally {
    lock.releaseLock();
  }
}

// Lets you confirm the deployment is live by opening the /exec URL in a browser.
function doGet() {
  return ContentService.createTextOutput(JSON.stringify({ ok: true, info: 'HeyOverHere collector is live. POST trials here.' }))
    .setMimeType(ContentService.MimeType.JSON);
}
