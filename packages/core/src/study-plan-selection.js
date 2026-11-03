// Small, public selector metadata. The browser does not need the course graph.
export const branchKey = node => node.directionCode || node.code;
export const compatibleBranch = (route, chosen) => !chosen?.length ||
  route.slice(0, Math.min(route.length, chosen.length)).every((key, i) => key === chosen[i]);

export function selectedPeriodNumbers(plan, selection) {
  return Array.from({ length: plan.studyYears * 2 }, (_, i) => i + 1).filter(number => {
    const term = (number % 2 === 1) === (plan.startTerm === 'autumn') ? 'autumn' : 'spring';
    return (!selection.studyYear || Math.ceil(number / 2) === selection.studyYear) &&
      (!selection.term || term === selection.term);
  });
}

export function studyPlanOptions(catalog) {
  const programmes = new Map();
  for (const [id, plan] of Object.entries(catalog.plans).sort(([a], [b]) => a.localeCompare(b))) {
    const branches = new Map();
    const walk = (id, path = [], names = [], ancestors = new Set()) => {
      const node = catalog.nodes[id];
      if (!node || ancestors.has(id) || ancestors.size > 12) throw new Error('Invalid study-plan direction graph.');
      const key = branchKey(node);
      if (key) {
        path = [...path, key]; names = [...names, node.name || key];
        branches.set(JSON.stringify(path), { path, name: names.join(' / ') });
      }
      for (const choice of node.choices) for (const child of choice.nodeIDs)
        walk(child, path, names, new Set([...ancestors, id]));
    };
    plan.periods.forEach(period => walk(period.nodeID));
    if (!programmes.has(plan.programmeCode)) programmes.set(plan.programmeCode,
      { programmeCode: plan.programmeCode, defaultAdmissionYear: catalog.defaultAdmissionYears?.[plan.programmeCode], plans: [] });
    programmes.get(plan.programmeCode).plans.push({ planID: id, admissionYear: plan.admissionYear,
      name: plan.name, studyYears: plan.studyYears, startTerm: plan.startTerm, sourceURL: plan.sourceURL,
      publishedPeriods: plan.periods.map(period => period.number), branches: [...branches.values()].sort((a, b) => a.name.localeCompare(b.name)) });
  }
  for (const programme of programmes.values()) {
    programme.plans.sort((a, b) => b.admissionYear - a.admissionYear);
    if (!programme.plans.some(p => p.admissionYear === programme.defaultAdmissionYear))
      programme.defaultAdmissionYear = programme.plans.some(p => p.admissionYear === 2023) ? 2023 : programme.plans[0].admissionYear;
  }
  return { schemaVersion: 1, programmes: [...programmes.values()] };
}
