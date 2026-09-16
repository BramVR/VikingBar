export const samples = {
  personal: { name: 'Personal SIM', factor: 1, bundles: [
    { name: 'Monthly data', remaining: 36, total: 50, expiry: '21 Sep', days: 5, cycleStart: 4, cycleDays: 30, detail: 'Monthly data for your personal SIM.' },
    { name: 'Extra data', remaining: 2.5, total: 5, expiry: '25 Sep', days: 9, cycleStart: 21, cycleDays: 17, detail: 'A separate extra-data bundle with its own expiry.' },
  ], charges: '€0.00' },
  work: { name: 'Work SIM', factor: 0.7, bundles: [
    { name: 'Monthly data', remaining: 8, total: 20, expiry: '30 Sep', days: 14, cycleStart: 14, cycleDays: 29, detail: 'Monthly data for your work SIM.' },
    { name: 'Extra data', remaining: 1.5, total: 3, expiry: '25 Sep', days: 9, cycleStart: 21, cycleDays: 17, detail: 'Extra data belonging only to your work SIM.' },
  ], charges: '€1.20' },
};

const dailyGB = [0.42, null, 0.68, 0.35, 0.54, 0.38, 0.72, 0.45, 0, 0.62, 0.87, 0.41, 0.55, 0.34, 0.76, 1.12, 0.48, 0.63, 0.29, 0.84, 0.51, 0.44, 0.69, 0.36, 0.93, 0.57, 0.4, 0.78, 0.52, 0.24];
export function historyDays(sim) {
  return dailyGB.map((amount, index) => {
    const date = new Date(Date.UTC(2026, 7, 18 + index));
    return {
      date: date.toISOString().slice(0, 10),
      label: date.toLocaleDateString('en-GB', {day: 'numeric', month: 'short', timeZone: 'UTC'}),
      fullDate: date.toLocaleDateString('en-GB', {day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC'}),
      gb: amount === null ? null : Math.round(amount * samples[sim].factor * 1000) / 1000,
      status: amount === null ? 'Missing' : index === 29 ? 'Partial today' : amount === 0 ? 'Confirmed zero' : 'Confirmed',
    };
  });
}

export function cycleSummary(days, bundle) {
  const cycle = days.slice(bundle.cycleStart);
  const complete = cycle.slice(0, -1);
  const observed = cycle.some(day => day.gb === null) ? null : cycle.reduce((sum, day) => sum + day.gb, 0);
  const estimate = complete.length < 3 || complete.some(day => day.gb === null)
    ? null : complete.reduce((sum, day) => sum + day.gb, 0) / complete.length * bundle.cycleDays;
  return {observed, estimate};
}

export function formatData(gb, unit = 'GB', digits = 2) {
  if (gb === null) return 'Unavailable';
  return `${new Intl.NumberFormat('en', {maximumFractionDigits: digits}).format(unit === 'GiB' ? gb / 1.073741824 : gb)} ${unit}`;
}

export const paymentFields = [
  {label: 'Recipient', value: 'Mobile Vikings NV'},
  {label: 'IBAN', value: 'BE02 7370 2691 7240', copy: 'BE02737026917240'},
  {label: 'BIC', value: 'KREDBEBB'},
  {label: 'Reference', value: '+++202/6091/60127+++'},
];
