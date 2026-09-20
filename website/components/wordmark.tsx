export function Wordmark() {
  return (
    <span className="flex items-center gap-2">
      <svg viewBox="0 0 24 24" className="size-5" aria-hidden="true" fill="none">
        {/* An arc between two points: a connection held open. */}
        <path
          d="M3 18a9 9 0 0 1 18 0"
          stroke="currentColor"
          strokeWidth="2.25"
          strokeLinecap="round"
          className="text-[var(--color-arc-live)]"
        />
        <circle cx="12" cy="18" r="1.75" fill="currentColor" />
      </svg>
      <span className="font-semibold tracking-tight">Arc</span>
    </span>
  );
}
