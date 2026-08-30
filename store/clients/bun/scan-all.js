
function scan_request_options(page_size, cursor, signal) {
  const page = Object.fromEntries(((cursor != null) ? [["limit", page_size], ["cursor", cursor]] : [["limit", page_size]]));
  return Object.fromEntries(((signal != null) ? [["page", page], ["signal", signal]] : [["page", page]]));
}

function scan_result(triples, served_version, pages) {
  return Object.fromEntries([["result", triples], ["servedVersion", served_version], ["pages", pages]]);
}

async function drain_scan(client, pattern, options, scan_page, max_page_limit, fail_page) {
  const requested_page_size = options.pageSize;
  const page_size = ((requested_page_size != null) ? requested_page_size : max_page_limit);
  const signal = options.signal;
  return (async () => { let cursor = null; let seen_cursors = []; let pinned_version = null; let pages = 0; let triples = []; while (true) {
    const response = await scan_page(client, pattern, scan_request_options(page_size, cursor, signal)); const page = response.page; const served_version = response.servedVersion; const chunk = response.result; ((!(page != null)) ? (() => { return fail_page("scan response has no page metadata"); })() : null); ((!(served_version != null)) ? (() => { return fail_page("scan response has no servedVersion"); })() : null); ((!Array.isArray(chunk)) ? (() => { return fail_page("scan response result is not an array"); })() : null); (((pinned_version != null) && (!Object.is(pinned_version, served_version))) ? (() => { return fail_page("scan continuation changed its pinned servedVersion"); })() : null); const done = page.done; const next_cursor = page.nextCursor; const next_pages = (pages + 1); const next_triples = triples.concat(chunk); const next_version = ((pinned_version != null) ? pinned_version : served_version); ((!((done === true) || (done === false))) ? (() => { return fail_page("scan response page.done is not boolean"); })() : null); if (done) { return (() => { if ((next_cursor != null)) {
  fail_page("complete scan page retained a continuation cursor");
}
return scan_result(next_triples, next_version, next_pages); })(); } else { ((!(next_cursor != null)) ? (() => { return fail_page("incomplete scan page has no continuation cursor"); })() : null); const cursor_key = JSON.stringify(next_cursor); (seen_cursors.includes(cursor_key) ? (() => { return fail_page("scan continuation cursor repeated before completion"); })() : null); const _recur_0 = next_cursor; const _recur_1 = seen_cursors.concat([cursor_key]); const _recur_2 = next_version; const _recur_3 = next_pages; const _recur_4 = next_triples; cursor = _recur_0; seen_cursors = _recur_1; pinned_version = _recur_2; pages = _recur_3; triples = _recur_4; continue; }
  } })();
}

function scan_all(client, pattern, options, scan_page, max_page_limit, fail_page) {
  return drain_scan(client, pattern, options, scan_page, max_page_limit, fail_page);
}
export { scan_all as "scan-all" };
