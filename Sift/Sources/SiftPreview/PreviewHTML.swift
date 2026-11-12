import Foundation

// The preview page. Quick Look draws HTML in its own sandboxed web view, so the page is one
// self-contained string: no script, no remote resource (the CSP below forbids both), inline styles
// that follow light and dark through `prefers-color-scheme`. `Appearance` exists only so the
// command line can render both without flipping the system setting.

public enum PreviewAppearance: String, Sendable {
    case system, light, dark
}

public func escapeHTML(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for ch in text.unicodeScalars {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default:
            // Control characters other than tab/newline are not valid in HTML text.
            if ch.value < 0x20 || ch.value == 0x7F { out += "\u{FFFD}" } else { out.unicodeScalars.append(ch) }
        }
    }
    return out
}

public func renderPreviewHTML(_ model: PreviewModel, appearance: PreviewAppearance = .system) -> String {
    var body = "<header><h1>\(escapeHTML(model.fileName))</h1>"
    for fact in model.headerFacts { body += "<span class=\"fact\">\(escapeHTML(fact))</span>" }
    body += "</header>\n"

    switch model.state {
    case .table(let table):
        body += "<main>" + renderTable(table)
        if table.rows.isEmpty { body += "<p class=\"note\">This file has no rows.</p>" }
        body += "</main>\n"
        var notes: [String] = []
        if table.moreRows { notes.append("Showing the first \(table.rows.count) rows.") }
        if table.hiddenColumns > 0 { notes.append("\(table.hiddenColumns) more columns not shown.") }
        if !notes.isEmpty { body += "<footer>\(escapeHTML(notes.joined(separator: " ")))</footer>\n" }
    case .timedOut:
        body += "<main class=\"message\"><p>Preview took too long.</p></main>\n"
    case .declined(let sentence), .unreadable(let sentence):
        body += "<main class=\"message\"><p>\(escapeHTML(sentence))</p></main>\n"
    }

    let theme = appearance == .system ? "" : " data-theme=\"\(appearance.rawValue)\""
    return """
        <!doctype html>
        <html lang="en"\(theme)><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <meta name="color-scheme" content="light dark">
        <title>\(escapeHTML(model.fileName))</title>
        <style>\(previewCSS)</style></head>
        <body>
        \(body)</body></html>
        """
}

private func renderTable(_ table: PreviewTable) -> String {
    var html = "<table><thead><tr><th class=\"n\"></th>"
    for column in table.columns {
        let align = column.rightAligned ? " class=\"r\"" : ""
        html += "<th\(align)><span class=\"name\">\(escapeHTML(column.name))</span>"
        html += "<span class=\"type\">\(escapeHTML(column.type.lowercased()))</span></th>"
    }
    html += "</tr></thead><tbody>\n"
    for (index, row) in table.rows.enumerated() {
        html += "<tr><td class=\"n\">\(index + 1)</td>"
        for (cell, column) in zip(row, table.columns) {
            var classes: [String] = []
            if column.rightAligned { classes.append("r") }
            switch cell.style {
            case .null: classes.append("null")
            case .empty: classes.append("empty")
            case .normal: break
            }
            let attr = classes.isEmpty ? "" : " class=\"\(classes.joined(separator: " "))\""
            html += "<td\(attr)>\(escapeHTML(cell.text))</td>"
        }
        html += "</tr>\n"
    }
    html += "</tbody></table>"
    return html
}

// Corner scale and type follow the suite: system font, 11pt floor, tabular figures.
private let previewCSS = """
    :root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--dim:#6e6e73;--faint:#98989d;--line:rgba(0,0,0,.1);--head:#f5f5f7;--zebra:rgba(0,0,0,.025);--accent:#f05323}
    @media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#1e1e1e;--fg:#f5f5f7;--dim:#a1a1a6;--faint:#6e6e73;--line:rgba(255,255,255,.12);--head:#2a2a2c;--zebra:rgba(255,255,255,.03)}}
    :root[data-theme=dark]{color-scheme:dark;--bg:#1e1e1e;--fg:#f5f5f7;--dim:#a1a1a6;--faint:#6e6e73;--line:rgba(255,255,255,.12);--head:#2a2a2c;--zebra:rgba(255,255,255,.03)}
    :root[data-theme=light]{color-scheme:light}
    *{box-sizing:border-box}
    html,body{height:100%;margin:0}
    body{display:flex;flex-direction:column;background:var(--bg);color:var(--fg);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;font-variant-numeric:tabular-nums;-webkit-font-smoothing:antialiased}
    header{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 16px;padding:12px 16px;border-bottom:1px solid var(--line);background:var(--head)}
    h1{margin:0;font-size:15px;font-weight:600;letter-spacing:-.01em}
    .fact{color:var(--dim);font-size:12px}
    main{flex:1;overflow:auto;min-height:0}
    .note{color:var(--dim);padding:24px;text-align:center;margin:0}
    main.message{display:flex;align-items:center;justify-content:center}
    main.message p{color:var(--dim);margin:0;padding:24px;text-align:center;max-width:52ch}
    table{border-collapse:separate;border-spacing:0;min-width:100%}
    th,td{padding:5px 12px;white-space:nowrap;max-width:36ch;overflow:hidden;text-overflow:ellipsis;border-bottom:1px solid var(--line);text-align:left}
    th{position:sticky;top:0;z-index:1;background:var(--head);font-weight:600;vertical-align:bottom;padding-top:7px;padding-bottom:7px}
    th .name{display:block;overflow:hidden;text-overflow:ellipsis}
    th .type{display:block;color:var(--faint);font-size:11px;font-weight:400;letter-spacing:.02em}
    .r{text-align:right}
    td.n,th.n{color:var(--faint);text-align:right;font-size:11px;position:sticky;left:0;background:var(--head);min-width:3.5ch}
    td.n{z-index:0}
    th.n{z-index:2}
    tbody tr:nth-child(even) td:not(.n){background:var(--zebra)}
    td.null{color:var(--faint);font-style:italic}
    td.empty{color:var(--faint)}
    footer{padding:6px 16px;border-top:1px solid var(--line);background:var(--head);color:var(--dim);font-size:11px}
    """
