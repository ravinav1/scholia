import Foundation

/// The only result data allowed across the WebKit boundary. Keep this out of
/// StudyLibrary, web state and search indexes. Native exam advice may send only
/// the passed course codes, after the user submits an advice question.
struct StudyCourseCompletion: Codable, Equatable, Sendable, Identifiable {
    let courseCode: String
    let passed: Bool
    var id: String { courseCode }
}

enum StudentwebResults {
    static let maximumCourses = 1_000
    static let maximumBytes = 80_000
    static let resultsURL = URL(string: "https://fsweb.no/studentweb/resultater.jsf")!

    static func resultsPage(_ url: URL) -> Bool {
        StudentwebExtraction.trusted(url) && url.path.lowercased() == "/studentweb/resultater.jsf"
    }

    static func validCode(_ code: String) -> Bool {
        code.range(of: #"\A[A-ZÆØÅ]{2,8}[0-9]{3,5}[A-Z]?\z"#, options: .regularExpression) != nil
    }

    /// Reject the entire payload if its schema changes. Never interpolate the
    /// payload or decoder errors into diagnostics, UI, telemetry or logs.
    static func parse(_ text: String) throws -> [StudyCourseCompletion] {
        guard text.utf8.count <= maximumBytes, let data = text.data(using: .utf8),
            let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            rows.count <= maximumCourses else { throw invalid }
        var seen = Set<String>()
        return try rows.map { row in
            guard Set(row.keys) == ["courseCode", "passed"],
                let code = row["courseCode"] as? String, validCode(code), seen.insert(code).inserted,
                let number = row["passed"] as? NSNumber,
                CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid }
            return StudyCourseCompletion(courseCode: code, passed: number.boolValue)
        }.sorted { $0.courseCode < $1.courseCode }
    }

    static var invalid: StudyError { .message("Could not safely read course pass statuses. No saved statuses were changed.") }

    // Runs only in the isolated WebKit content world after a user starts a check.
    // Nothing from the page is returned except validated course codes and bools.
    // No fetch, form values, full-page text, links, HTML or page-authored JS.
    static let script = #"""
    if (location.protocol !== 'https:' || location.hostname !== 'fsweb.no' || location.username || location.password ||
        (location.port && location.port !== '443') || location.pathname.toLowerCase() !== '/studentweb/resultater.jsf') return '';
    const ignored = 'script,style,noscript,template,input,textarea,select,iframe,nav,header,footer,[role="navigation"],.ui-column-title,.statistikkButton';
    const headingSelector = 'h1,h2,h3,h4,[role="heading"],caption,.ui-panel-title,.ui-datatable-header';
    const resultHeading = /^(?:mine resultater|mine resultat|my results|results|resultater|resultat|exam results|eksamensresultater|completed courses|fullførte emner|beståtte emner)(?:\s*\(\d+\))?$/i;
    const partialHeading = /del(er|ar)?\b|parts?\b|components?\b|partial|ikke beregnet|ikkje rekna|not calculated|not completed/i;
    function visible(node, courseLabel = false) {
      const courseCell = courseLabel ? node.closest('td') : null;
      for (let element = node; element?.nodeType === 1; element = element.parentElement) {
        // Studentweb's displayed course code is aria-hidden because a separate
        // screen-reader label repeats it. This is not CSS visibility. Permit
        // that presentation text only inside the already-visible course cell.
        const hiddenFromAccessibility = element.getAttribute('aria-hidden') === 'true' &&
          !(courseCell && element !== courseCell && courseCell.contains(element));
        if (element.hasAttribute('hidden') || hiddenFromAccessibility ||
            element.matches('.ui-helper-hidden,.ui-helper-hidden-accessible,.uuHidden')) return false;
        const style = document.defaultView?.getComputedStyle?.(element) || element.style;
        if (style?.display === 'none' || ['hidden', 'collapse'].includes(style?.visibility) || style?.opacity === '0') return false;
        if (element.tagName === 'DETAILS' && !element.hasAttribute('open') && !element.querySelector('summary')?.contains(node)) return false;
      }
      return typeof node.getClientRects !== 'function' || node.getClientRects().length > 0;
    }
    function text(node, header = false, courseLabel = false) {
      if (node.nodeType === 3) return node.textContent;
      if (node.nodeType !== 1 || node.matches('table') || (!header && node.matches(ignored)) || !visible(node, courseLabel)) return '';
      if (!header && node.tagName === 'BUTTON' && !courseLabel) return '';
      if (header && node.matches('script,style,input,textarea,select,button')) return '';
      if (!header && node.tagName === 'A' && /^(?:statistikk for|statistics for)(?:\s+[A-ZÆØÅ]{2,8}\d{3,5}[A-Z]?)?$/i.test(node.textContent.trim())) return '';
      const value = [...node.childNodes].map(child => text(child, header, courseLabel)).join('');
      // Responsive/accessibility spans may repeat a code with no literal
      // whitespace between elements. Preserve those element boundaries.
      return /^(BR|P|DIV|LI|TD|TH|SPAN|A|BUTTON|H[1-6])$/.test(node.tagName) ? '\n' + value + '\n' : value;
    }
    const clean = (node, header = false, courseLabel = false) => text(node, header, courseLabel).replace(/\s+/g, ' ').trim();
    // Captions can be visually hidden while still naming a visible table for
    // assistive technology. Read only these bounded semantic labels; result
    // rows and cells must still be visible.
    const headingLabel = node => {
      const label = node.textContent.replace(/\s+/g, ' ').trim();
      return label.length <= 160 ? label : '';
    };
    function resultsTable(table) {
      // The nearest section heading wins. Never borrow "Results" from another
      // panel or accept the separate table of incomplete assessment components.
      const ownHeadings = [...table.querySelectorAll(headingSelector)].filter(h => h.closest('table') === table);
      if (ownHeadings.length) {
        const labels = ownHeadings.map(headingLabel);
        return !labels.some(t => partialHeading.test(t)) && labels.some(t => resultHeading.test(t));
      }
      for (let node = table; node && node !== document.body; node = node.parentElement) {
        let previous = node.previousElementSibling;
        // Studentweb may put a short help paragraph between a title and table.
        for (let i = 0; previous && i < 8; i++, previous = previous.previousElementSibling) {
          if (previous.matches('table') || previous.querySelector('table')) return false;
          const heading = previous.matches(headingSelector) ? previous : [...previous.querySelectorAll(headingSelector)].at(-1);
          if (heading) {
            const label = headingLabel(heading);
            return !partialHeading.test(label) && resultHeading.test(label);
          }
        }
      }
      return false;
    }
    const values = new Map();
    let examined = 0;
    const tables = [...document.querySelectorAll('table')].filter(t => !t.parentElement?.closest('table'));
    if (tables.length > 100) return '';
    for (const table of tables.filter(t => visible(t) && resultsTable(t))) {
      // Nested detail tables cannot supply a course-wide result.
      if (table.parentElement?.closest('table')) continue;
      const rows = [...table.querySelectorAll('tr')].filter(r => r.closest('table') === table && visible(r));
      const header = rows.find(r => r.querySelector('th'));
      if (!header) continue;
      const titles = [...header.children].map(cell => clean(cell, true).toLowerCase());
      const column = re => { const hits = titles.flatMap((t, i) => re.test(t) ? [i] : []); return hits.length === 1 ? hits[0] : -1; };
      const courseIndex = column(/^(emne|emnekode|course|course code)$/);
      const gradeIndex = column(/^(karakter|grade|resultat|result|samlet resultat|overall result)$/);
      const creditsIndex = column(/^(studiepoeng|credits|ects|sp|stp\.?)$/);
      const componentIndex = column(/^(vurdering|vurderingsdel|vurderingstype|assessment|assessment type|assessment component|component|del)$/);
      const basisIndex = column(/^(vurderingsgrunnlag|assessment basis)$/);
      // Bind the known results table, but never read credit values: retakes may
      // have blank credits, and complete zero-credit courses are valid too.
      if (courseIndex < 0 || gradeIndex < 0 || creditsIndex < 0) continue;
      for (const row of rows) {
        if (row === header || row.querySelector('th')) continue;
        if (++examined > 2000) return '';
        const cells = [...row.children];
        if (cells.length !== titles.length || cells.some(c => c.hasAttribute('colspan') || c.hasAttribute('rowspan'))) continue;
        if (row.matches('.resultat,.ui-expanded-row-content,[role="rowgroup"]') || row.closest('.ui-expanded-row-content')) continue;
        if (cells.some(c => c.querySelector('table'))) continue;
        if (componentIndex >= 0 && !/^(?:|samlet|samlet karakter|samlet resultat|samlet vurdering|samla vurdering|hele emnet|overall|overall result|overall assessment|total assessment|whole course)$/i.test(clean(cells[componentIndex]))) continue;
        if (basisIndex >= 0 && /^(?:del|part|component)\s*:/i.test(clean(cells[basisIndex]).replace(/^(?:vurderingsgrunnlag|assessment basis)\s+/i, ''))) continue;
        // Studentweb renders course codes as buttons that open course details.
        // Read only their visible labels in the course column; never click them
        // or read form values. Buttons in result cells remain excluded.
        const courseText = clean(cells[courseIndex], false, true).replace(/^(?:emne|course)\s+/i, '');
        if (courseText.length > 500) continue;
        // Require a code at the beginning, not a code incidentally in a title.
        const code = courseText.match(/^([A-ZÆØÅ]{2,8})[- ]?([0-9]{3,5}[A-Z]?)(?=$|\s|[–—:])/);
        const codes = new Set([...courseText.matchAll(/(?:^|[^A-ZÆØÅa-zæøå0-9])([A-ZÆØÅ]{2,8})[- ]?([0-9]{3,5}[A-Z]?)(?=$|[^A-ZÆØÅa-zæøå0-9])/g)].map(m => m[1] + m[2]));
        // Responsive markup can repeat the same code. Different codes in one
        // cell are ambiguous; Unicode boundaries must include Æ, Ø and Å.
        if (!code || codes.size !== 1 || !codes.has(code[1] + code[2])) continue;
        const grade = clean(cells[gradeIndex]).replace(/^(?:resultat|karakter|result|grade)\s+/i, '').toLowerCase();
        let passed;
        if (/^(?:[a-e]|bestått|greidd|pass|passed)$/.test(grade)) passed = true;
        else if (/^(?:f|ikke bestått|ikkje bestått|ikkje greidd|fail|failed|not passed)$/.test(grade)) passed = false;
        else continue; // Pending, withdrawn, exempted, numeric and unknown scales.
        const courseCode = code[1] + code[2];
        // A passed complete attempt remains passed even if a retake failed.
        values.set(courseCode, values.get(courseCode) === true || passed);
        if (values.size > 1000) return '';
      }
    }
    return JSON.stringify([...values].sort(([a], [b]) => a.localeCompare(b)).map(([courseCode, passed]) => ({courseCode, passed})));
    """#
}
