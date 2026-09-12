import type { APIRoute } from "astro";

// `import.meta.env.BASE_URL` may or may not end with a slash, so normalize it
// to make the paths below correct both at the site root and under a sub-path.
const base = import.meta.env.BASE_URL.replace(/\/$/, "");

const robotsTxt = `
User-agent: *
Disallow: ${base}/_astro/

Sitemap: ${new URL(`${base}/sitemap-index.xml`, import.meta.env.SITE).href}
`.trim();

export const GET: APIRoute = () => {
	return new Response(robotsTxt, {
		headers: {
			"Content-Type": "text/plain; charset=utf-8",
		},
	});
};
