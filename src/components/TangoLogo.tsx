import { cn } from '@/lib/utils';

// Hand-traced approximation of the Tango app icon: an orange curl, a pink dot,
// and a tilted purple bean over a cream rounded-square background. Colors
// mirror the brand palette tokens in globals.css; kept as hex literals because
// SVG fill can't read OKLCH CSS vars in all browsers.
const TANGO_PEACH = '#F4885F';
const TANGO_PINK = '#EE5C9E';
const TANGO_PURPLE = '#6E5DD0';

type Props = {
  className?: string;
  withBackground?: boolean;
};

export default function TangoLogo({
  className,
  withBackground = false,
}: Props) {
  return (
    <svg
      viewBox="0 0 200 200"
      xmlns="http://www.w3.org/2000/svg"
      role="img"
      aria-label="Tango"
      className={cn('shrink-0', className)}
    >
      {withBackground && (
        <rect width="200" height="200" rx="44" fill="#F4EEDF" />
      )}
      {/* Orange curl, lower-left */}
      <path
        d="M 40 100
           C 28 78, 38 48, 65 44
           C 92 40, 110 62, 104 88
           C 98 114, 80 130, 60 128
           C 42 126, 32 116, 40 100 Z"
        fill={TANGO_PEACH}
      />
      {/* Tilted purple bean, lower-right */}
      <ellipse
        cx="140"
        cy="118"
        rx="38"
        ry="22"
        transform="rotate(22 140 118)"
        fill={TANGO_PURPLE}
      />
      {/* Pink dot, upper-center */}
      <circle cx="116" cy="58" r="22" fill={TANGO_PINK} />
    </svg>
  );
}
