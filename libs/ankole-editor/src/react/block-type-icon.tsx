import {
  RiAtLine,
  RiFlowChart,
  RiFormula,
  RiH4,
  RiH5,
  RiH6,
  RiTableLine,
  RiImageLine,
  RiFileLine,
  RiLink
} from '@remixicon/react'
import type { ReactElement } from 'react'
import type { BlockType } from '../editor/block-catalog'

// Original vector paths from Pleisto's Web UI Blocks and q icon library.
// The slash menu adds its own tile; other menus use the plain glyph.
const glyphs = {
  h1: (
    <svg viewBox="0 0 15 15" fill="none">
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M2.36357 2.65909C2.52674 2.65909 2.65902 2.79137 2.65902 2.95454V11.836C2.65902 11.9992 2.52674 12.1315 2.36357 12.1315C2.20039 12.1315 2.06812 11.9992 2.06812 11.836V2.95454C2.06812 2.79137 2.20039 2.65909 2.36357 2.65909Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M7.63701 2.65909C7.80018 2.65909 7.93246 2.79137 7.93246 2.95454V11.836C7.93246 11.9992 7.80018 12.1315 7.63701 12.1315C7.47383 12.1315 7.34155 11.9992 7.34155 11.836V2.95454C7.34155 2.79137 7.47383 2.65909 7.63701 2.65909Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M2.06812 7.39531C2.06812 7.23213 2.20039 7.09985 2.36357 7.09985H7.63696C7.80014 7.09985 7.93242 7.23213 7.93242 7.39531C7.93242 7.55848 7.80014 7.69076 7.63696 7.69076H2.36357C2.20039 7.69076 2.06812 7.55848 2.06812 7.39531Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M11.6327 5.73801C11.7447 5.78298 11.818 5.89151 11.818 6.01217V11.836C11.818 11.9992 11.6857 12.1315 11.5226 12.1315C11.3594 12.1315 11.2271 11.9992 11.2271 11.836V6.74768L10.4109 7.59969C10.298 7.71752 10.111 7.72153 9.99317 7.60865C9.87534 7.49577 9.87132 7.30874 9.9842 7.19091L11.3092 5.80778C11.3927 5.72066 11.5207 5.69303 11.6327 5.73801Z"
        fill="currentColor"
      />
    </svg>
  ),
  h2: (
    <svg viewBox="0 0 15 15" fill="none">
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M2.36357 2.65909C2.52674 2.65909 2.65902 2.79137 2.65902 2.95454V11.3586C2.65902 11.5218 2.52674 11.654 2.36357 11.654C2.20039 11.654 2.06812 11.5218 2.06812 11.3586V2.95454C2.06812 2.79137 2.20039 2.65909 2.36357 2.65909Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M7.09086 2.65909C7.25404 2.65909 7.38632 2.79137 7.38632 2.95454V11.3586C7.38632 11.5218 7.25404 11.654 7.09086 11.654C6.92769 11.654 6.79541 11.5218 6.79541 11.3586V2.95454C6.79541 2.79137 6.92769 2.65909 7.09086 2.65909Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M2.33081 7.15657C2.33081 6.99339 2.46309 6.86111 2.62627 6.86111H6.82829C6.99146 6.86111 7.12374 6.99339 7.12374 7.15657C7.12374 7.31974 6.99146 7.45202 6.82829 7.45202H2.62627C2.46309 7.45202 2.33081 7.31974 2.33081 7.15657Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M10.5051 6.40152C10.0226 6.40152 9.48739 6.78178 9.48739 7.41919C9.48739 7.58237 9.35511 7.71465 9.19194 7.71465C9.02876 7.71465 8.89648 7.58237 8.89648 7.41919C8.89648 6.39334 9.76199 5.81061 10.5051 5.81061C11.2482 5.81061 12.1137 6.39334 12.1137 7.41919C12.1137 7.88232 11.9104 8.29373 11.6461 8.65393C11.3824 9.01322 11.0355 9.35104 10.7099 9.66422C10.6923 9.68109 10.6748 9.69789 10.6574 9.71462C10.3434 10.0164 10.0533 10.2952 9.835 10.5742C9.69727 10.7503 9.60025 10.9118 9.54433 11.0631H11.8182C11.9814 11.0631 12.1137 11.1954 12.1137 11.3586C12.1137 11.5218 11.9814 11.654 11.8182 11.654H9.19194C9.02876 11.654 8.89648 11.5218 8.89648 11.3586C8.89648 10.9279 9.10829 10.5442 9.36958 10.2102C9.6148 9.89669 9.93374 9.59037 10.2379 9.29822C10.2588 9.27818 10.2796 9.25821 10.3003 9.2383C10.6312 8.92009 10.9409 8.61612 11.1696 8.30434C11.3978 7.99348 11.5227 7.70456 11.5227 7.41919C11.5227 6.78178 10.9876 6.40152 10.5051 6.40152Z"
        fill="currentColor"
      />
    </svg>
  ),
  h3: (
    <svg viewBox="0 0 15 15" fill="none">
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M2.36357 2.65909C2.52674 2.65909 2.65902 2.79137 2.65902 2.95454V11.3586C2.65902 11.5218 2.52674 11.654 2.36357 11.654C2.20039 11.654 2.06812 11.5218 2.06812 11.3586V2.95454C2.06812 2.79137 2.20039 2.65909 2.36357 2.65909Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M7.09086 2.65909C7.25404 2.65909 7.38632 2.79137 7.38632 2.95454V11.3586C7.38632 11.5218 7.25404 11.654 7.09086 11.654C6.92769 11.654 6.79541 11.5218 6.79541 11.3586V2.95454C6.79541 2.79137 6.92769 2.65909 7.09086 2.65909Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M2.33081 7.15656C2.33081 6.99339 2.46309 6.86111 2.62627 6.86111H6.82829C6.99146 6.86111 7.12374 6.99339 7.12374 7.15656C7.12374 7.31974 6.99146 7.45202 6.82829 7.45202H2.62627C2.46309 7.45202 2.33081 7.31974 2.33081 7.15656Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M8.89649 6.10605C8.89649 5.94288 9.02877 5.8106 9.19194 5.8106H11.8182C11.931 5.8106 12.034 5.87488 12.0836 5.97625C12.1332 6.07762 12.1207 6.19837 12.0514 6.28745L10.5446 8.22485C10.8961 8.29113 11.2165 8.42408 11.4775 8.63292C11.882 8.95651 12.1137 9.43858 12.1137 10.0454C12.1137 10.6551 11.8795 11.0746 11.5359 11.3323C11.2065 11.5793 10.8089 11.654 10.5051 11.654C9.78747 11.654 9.28556 11.3493 8.97332 11.0058C8.86356 10.8851 8.87246 10.6982 8.9932 10.5884C9.11394 10.4787 9.3008 10.4876 9.41056 10.6083C9.62358 10.8426 9.97204 11.0631 10.5051 11.0631C10.7265 11.0631 10.9854 11.0065 11.1813 10.8596C11.3629 10.7234 11.5227 10.4863 11.5227 10.0454C11.5227 9.60182 11.3605 9.29601 11.1084 9.09434C10.8474 8.88558 10.46 8.76515 9.97982 8.76515C9.86698 8.76515 9.76399 8.70087 9.71441 8.5995C9.66483 8.49813 9.67732 8.37737 9.7466 8.2883L11.2141 6.40151H9.19194C9.02877 6.40151 8.89649 6.26923 8.89649 6.10605Z"
        fill="currentColor"
      />
    </svg>
  ),
  bullet: (
    <svg viewBox="0 0 15 15" fill="none">
      <path
        d="M2.95443 11.8182C3.28078 11.8182 3.54534 11.5536 3.54534 11.2273C3.54534 10.9009 3.28078 10.6364 2.95443 10.6364C2.62808 10.6364 2.36353 10.9009 2.36353 11.2273C2.36353 11.5536 2.62808 11.8182 2.95443 11.8182Z"
        fill="currentColor"
      />
      <path
        d="M2.95443 3.54546C3.28078 3.54546 3.54534 3.28091 3.54534 2.95455C3.54534 2.6282 3.28078 2.36364 2.95443 2.36364C2.62808 2.36364 2.36353 2.6282 2.36353 2.95455C2.36353 3.28091 2.62808 3.54546 2.95443 3.54546Z"
        fill="currentColor"
      />
      <path
        d="M2.95443 7.68182C3.28078 7.68182 3.54534 7.41727 3.54534 7.09091C3.54534 6.76455 3.28078 6.5 2.95443 6.5C2.62808 6.5 2.36353 6.76455 2.36353 7.09091C2.36353 7.41727 2.62808 7.68182 2.95443 7.68182Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M6.20435 7.09091C6.20435 6.92774 6.33663 6.79546 6.4998 6.79546H12.4089C12.5721 6.79546 12.7043 6.92774 12.7043 7.09091C12.7043 7.25409 12.5721 7.38636 12.4089 7.38636H6.4998C6.33663 7.38636 6.20435 7.25409 6.20435 7.09091Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M6.20435 11.2273C6.20435 11.0641 6.33663 10.9318 6.4998 10.9318H12.4089C12.5721 10.9318 12.7043 11.0641 12.7043 11.2273C12.7043 11.3904 12.5721 11.5227 12.4089 11.5227H6.4998C6.33663 11.5227 6.20435 11.3904 6.20435 11.2273Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M6.20435 2.95455C6.20435 2.79137 6.33663 2.65909 6.4998 2.65909H12.4089C12.5721 2.65909 12.7043 2.79137 12.7043 2.95455C12.7043 3.11772 12.5721 3.25 12.4089 3.25H6.4998C6.33663 3.25 6.20435 3.11772 6.20435 2.95455Z"
        fill="currentColor"
      />
    </svg>
  ),
  embed: (
    <svg viewBox="0 0 15 15" fill="none">
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M1.47729 7.0909C1.47729 3.99057 3.9906 1.47726 7.09093 1.47726C10.1913 1.47726 12.7046 3.99057 12.7046 7.0909C12.7046 10.1912 10.1913 12.7045 7.09093 12.7045C3.9906 12.7045 1.47729 10.1912 1.47729 7.0909ZM7.09093 2.06817C4.31695 2.06817 2.0682 4.31692 2.0682 7.0909C2.0682 9.86488 4.31695 12.1136 7.09093 12.1136C9.86491 12.1136 12.1137 9.86488 12.1137 7.0909C12.1137 4.31692 9.86491 2.06817 7.09093 2.06817Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M5.89434 5.89431L4.69775 9.48409L8.28753 8.2875L9.48412 4.69772L5.89434 5.89431ZM7.62278 7.09091C7.62278 7.38463 7.38469 7.62273 7.09096 7.62273C6.79724 7.62273 6.55915 7.38463 6.55915 7.09091C6.55915 6.79718 6.79724 6.55909 7.09096 6.55909C7.38469 6.55909 7.62278 6.79718 7.62278 7.09091Z"
        fill="currentColor"
      />
    </svg>
  ),
  paragraph: (
    <svg viewBox="0 0 24 24" fill="none">
      <path d="M4 5H12" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M4 12H20" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M4 19H20" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  ),
  number: (
    <svg viewBox="0 0 24 24" fill="none">
      <path d="M6 4V7" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M7 7H5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M7 13H5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
      <path
        d="M5 10.48C5 10.48 6.11953 9.4 6.86589 10.48C7.61224 11.56 5 13 5 13"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M5.72726 18.0067C6.01128 18.0067 6.35233 18.0067 6.63635 18.0067"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M5 16.7651C5.18728 16.0722 5.61805 15.9419 6.09091 16.0201C6.56377 16.0982 7 16.5167 7 17.0134C7 17.5101 6.63636 17.7584 6.63636 18.0067C6.63636 18.2551 7 18.2551 7 19C7 19.4967 6.50371 19.95 6.09091 19.9934C5.616 20.0433 5.31015 19.8132 5 19.2484"
        stroke="currentColor"
        strokeLinecap="round"
      />
      <path d="M6 4H5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M11 12H20" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M11 18H20" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M11 6H20" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  ),
  code: (
    <svg viewBox="0 0 24 24" fill="none">
      <path d="M8.4 7.05L3 12.6445L8.4 17.85" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M15.6 7.05L21 12.6445L15.6 17.85" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M13.8 3L10.65 21" stroke="currentColor" strokeLinecap="round" />
    </svg>
  ),
  quote: (
    <svg viewBox="0 0 24 24" fill="none">
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M9.42665 4.55793C5.66135 6.97605 3.56957 9.79055 3.15128 13.0014C2.50011 17.9999 6.9702 20.4466 9.23515 18.2483C11.5001 16.05 10.1424 13.2597 8.50235 12.497C6.8623 11.7343 5.85935 11.9999 6.0343 10.9807C6.20925 9.9615 8.54255 7.1356 10.5925 5.81955C10.7285 5.7039 10.7802 5.4795 10.6493 5.30925C10.5631 5.1973 10.3942 4.97772 10.1424 4.65051C9.92225 4.36437 9.71135 4.37508 9.42665 4.55793Z"
        fill="currentColor"
      />
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M19.3395 4.55793C15.5742 6.97605 13.4824 9.79055 13.0641 13.0014C12.413 17.9999 16.8831 20.4466 19.148 18.2483C21.413 16.05 20.0553 13.2597 18.4152 12.497C16.7752 11.7343 15.7722 11.9999 15.9472 10.9807C16.1221 9.9615 18.4554 7.1356 20.5053 5.81955C20.6413 5.7039 20.6931 5.4795 20.5621 5.30925C20.476 5.1973 20.307 4.97772 20.0553 4.65051C19.8351 4.36437 19.6242 4.37508 19.3395 4.55793Z"
        fill="currentColor"
      />
    </svg>
  ),
  callout: (
    <svg viewBox="0 0 24 24" fill="none">
      <path
        d="M19 10.25C19 13.2284 17.1399 15.7723 14.518 16.7835H12H9.48197C6.86007 15.7723 5 13.2284 5 10.25C5 6.38399 8.13399 3.25 12 3.25C15.866 3.25 19 6.38399 19 10.25Z"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path d="M8.5 19L15.5 19" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M9.375 20.75H14.275" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  ),
  check: (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1"
      strokeLinecap="round"
      strokeLinejoin="round">
      <rect x="4" y="4" width="16" height="16" rx="2" />
      <path d="m8 12 3 3 5-6" />
    </svg>
  ),
  divider: (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1" strokeLinecap="round">
      <path d="M3 12h18" />
    </svg>
  ),
  h4: <RiH4 />,
  h5: <RiH5 />,
  h6: <RiH6 />,
  table: <RiTableLine />,
  media: <RiImageLine />,
  file: <RiFileLine />,
  bookmark: <RiLink />,
  mention: <RiAtLine />,
  math: <RiFormula />,
  mermaid: <RiFlowChart />
} satisfies Record<Exclude<BlockType, `columns${number}`>, ReactElement>

export function blockMenuGroup(type: BlockType) {
  if (type.startsWith('columns')) return 'layout_blocks'
  if (['mention', 'callout', 'embed', 'math', 'mermaid', 'media', 'file', 'bookmark'].includes(type)) {
    return 'advanced_blocks'
  }
  return 'basic_blocks'
}

export function BlockTypeIcon({ type }: { type: BlockType }) {
  const columns = type.startsWith('columns') ? Number(type.slice(-1)) : 0
  return (
    <span className="block-type-icon" data-block-type={type} aria-hidden="true">
      {columns ? (
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1">
          <rect x="3" y="4" width="18" height="16" rx="1" />
          {Array.from({ length: columns - 1 }, (_, index) => (
            <path key={index} d={`M${3 + (18 * (index + 1)) / columns} 4v16`} />
          ))}
        </svg>
      ) : (
        glyphs[type as keyof typeof glyphs]
      )}
    </span>
  )
}
