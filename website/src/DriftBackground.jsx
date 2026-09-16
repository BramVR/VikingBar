const pluses = Array.from({ length: 256 }, (_, index) => ({
  left: 2 + ((index * 37.7) % 96),
  top: (index + 0.5) * 48,
  size: 8 + (index * 7 % 9),
  duration: 12 + (index * 11 % 13),
  delay: -(index * 3.7 % 40),
}));

export function DriftBackground() {
  return <div className="drift-background" aria-hidden="true">
    {pluses.map((plus, index) => <span key={index} className={index % 10 === 0 ? 'drift-plus drift-red' : index % 3 !== 0 ? 'drift-plus drift-violet' : 'drift-plus'} style={{
      left: `${plus.left}%`, top: `${plus.top}px`, width: plus.size, height: plus.size,
      opacity: .18 + (index % 5) * .065, filter: index % 4 === 0 ? 'blur(1px)' : 'none', animationDuration: `${plus.duration}s`, animationDelay: `${plus.delay}s`,
    }}/>) }
  </div>;
}
