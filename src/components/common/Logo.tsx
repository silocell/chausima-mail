/*
 * SPDX-FileCopyrightText: 2020 Stalwart Labs LLC <hello@stalw.art>
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-SEL
 */

import { useEffect, useSyncExternalStore } from 'react';
import { useTranslation } from 'react-i18next';
import { getLogoState, loadLogoOnce, subscribeToLogo } from '@/lib/logoCache';

export function DefaultLogo() {
  const { t } = useTranslation();
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 330 64"
      aria-label={t('logo.stalwartAlt', 'Chausima Mail')}
      className="h-7 w-auto max-w-[320px]"
    >
      <g fill="none" stroke="#c8312b" strokeWidth="5">
        <circle cx="32" cy="32" r="27" />
        <path d="M18 25h28v15H18z" strokeWidth="4" />
        <path d="M18 25l14 10 14-10" strokeWidth="4" />
      </g>
      <text x="72" y="43" className="fill-current" fontSize="30" fontWeight="700" fontFamily="inherit">
        Chausima Mail
      </text>
    </svg>
  );
}

export default function Logo() {
  const { t } = useTranslation();
  const logo = useSyncExternalStore(subscribeToLogo, getLogoState, getLogoState);

  useEffect(() => {
    loadLogoOnce();
  }, []);

  if (logo.status === 'custom') {
    return <img src={logo.url} alt={t('logo.alt', 'Logo')} className="h-7 w-auto max-w-[220px] object-contain" />;
  }

  if (logo.status === 'loading') {
    return <span className="block h-7 w-[140px]" aria-hidden="true" />;
  }

  return <DefaultLogo />;
}
