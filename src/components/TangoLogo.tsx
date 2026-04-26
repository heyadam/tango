import { useId } from 'react';
import { cn } from '@/lib/utils';

type Props = {
  className?: string;
  withBackground?: boolean;
};

export default function TangoLogo({
  className,
  withBackground = false,
}: Props) {
  const uid = useId();
  const orangeId = `tango-orange-${uid}`;
  const pinkId = `tango-pink-${uid}`;
  const blueId = `tango-blue-${uid}`;

  return (
    <svg
      viewBox="0 0 1024 1024"
      xmlns="http://www.w3.org/2000/svg"
      role="img"
      aria-label="Tango"
      className={cn('shrink-0', className)}
    >
      <defs>
        <linearGradient
          id={orangeId}
          x1="151"
          y1="305"
          x2="707"
          y2="763"
          gradientUnits="userSpaceOnUse"
        >
          <stop offset="0" stopColor="#ff6048" />
          <stop offset="0.46" stopColor="#ff523e" />
          <stop offset="1" stopColor="#ff6149" />
        </linearGradient>

        <radialGradient
          id={pinkId}
          cx="0"
          cy="0"
          r="1"
          gradientUnits="userSpaceOnUse"
          gradientTransform="translate(505 291) rotate(45) scale(207)"
        >
          <stop offset="0" stopColor="#f86ab3" />
          <stop offset="0.62" stopColor="#f452a4" />
          <stop offset="1" stopColor="#f1589d" />
        </radialGradient>

        <linearGradient
          id={blueId}
          x1="593"
          y1="569"
          x2="877"
          y2="371"
          gradientUnits="userSpaceOnUse"
        >
          <stop offset="0" stopColor="#5b56e8" />
          <stop offset="0.56" stopColor="#5755e6" />
          <stop offset="1" stopColor="#5e61dc" />
        </linearGradient>
      </defs>

      {withBackground && (
        <rect width="1024" height="1024" rx="225" fill="#F4EEDF" />
      )}

      <path
        fill={`url(#${orangeId})`}
        d="M389.8 352.8c31.4 57.8 43.3 128.3 96.8 201.8 45.7 63.1 98.7 89.8 158.1 99.8 31.8 5.4 50.7 29.2 43.3 59.2-8.4 34-49.9 51.9-109.8 47.3-106.4-8.1-219.7-66.9-304.2-160.4-86.6-90.2-141.5-207-146.3-278.4-2-33.4 40.9-49.1 103.3-48.1 69.6 1.1 128.6 23.6 158.8 78.8Z"
      />

      <circle cx="544.4" cy="335.8" r="109.2" fill={`url(#${pinkId})`} />

      <path
        fill={`url(#${blueId})`}
        d="M611.2 580.7c-34.5-5.9-49.9-38.2-31.2-67.5 13.7-21.5 34.8-24.7 61.5-32.4 39.4-11.3 68.6-33.2 97.1-69.2 22.8-28.8 37.5-52.3 66.6-61 32.8-9.8 69.7 7.3 86.8 40 19.4 37.1 4.6 81.5-38.6 117.8-60.7 51-157.1 86.7-242.2 72.3Z"
      />
    </svg>
  );
}
