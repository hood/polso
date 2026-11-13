/** Prefixes the site base ("/polso") so links and media work wherever the site is mounted. */
export const withBase = (p: string) => import.meta.env.BASE_URL.replace(/\/$/, '') + '/' + p.replace(/^\//, '');
