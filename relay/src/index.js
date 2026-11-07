// Muzika catalog relay (Cloudflare Worker + Durable Object).
//
// YouTube Music hides its catalog (songs, albums, artists, clean metadata,
// square album art) from Ethiopian IPs. Workers run in the nearest Cloudflare
// colo (Addis Ababa), whose egress is also geolocated to ET, so the actual
// upstream call is made from a Durable Object pinned to Eastern North America.
// Audio never goes through here: the app streams it directly.

import { DurableObject } from 'cloudflare:workers';

const ALLOWED = new Set([
  'search',
  'browse',
  'next',
  'music/get_search_suggestions',
  'music/get_queue',
]);

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

const SHARDS = 4; // spread load over a few US-pinned instances

export class UsRelay extends DurableObject {
  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname === '/where') {
      const egress = await fetch('https://ipinfo.io/json').then((r) => r.json());
      return Response.json({ ip: egress.ip, country: egress.country, org: egress.org });
    }

    const endpoint = url.pathname.replace(/^\/youtubei\/v1\//, '');
    const upstream = new URL(`https://music.youtube.com/youtubei/v1/${endpoint}`);
    upstream.searchParams.set('prettyPrint', 'false');

    const headers = {
      'content-type': 'application/json',
      'user-agent': UA,
      origin: 'https://music.youtube.com',
      referer: 'https://music.youtube.com/',
      'accept-language': request.headers.get('accept-language') ?? 'en',
    };
    const visitor = request.headers.get('x-goog-visitor-id');
    if (visitor) headers['x-goog-visitor-id'] = visitor;

    const res = await fetch(upstream, {
      method: 'POST',
      headers,
      body: await request.text(),
    });
    return new Response(res.body, {
      status: res.status,
      headers: {
        'content-type': res.headers.get('content-type') ?? 'application/json',
        'cache-control': 'no-store',
      },
    });
  }
}

function relay(env) {
  const shard = Math.floor(Math.random() * SHARDS);
  const id = env.US_RELAY.idFromName(`us-${shard}`);
  return env.US_RELAY.get(id, { locationHint: 'enam' });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === '/health') {
      return new Response('ok', { headers: { 'cache-control': 'no-store' } });
    }

    // The caller's country from its IP (Cloudflare geolocation), for the
    // app's location-aware home screen. Nothing is stored.
    if (url.pathname === '/geo') {
      return Response.json(
        { country: request.cf?.country ?? null },
        { headers: { 'cache-control': 'no-store' } },
      );
    }

    if (url.pathname === '/where') {
      const inner = await relay(env).fetch('https://relay/where');
      return Response.json({ colo: request.cf?.colo, egress: await inner.json() });
    }

    if (request.method !== 'POST') {
      return new Response('Method not allowed', { status: 405 });
    }
    if (!env.MUZIKA_KEY || request.headers.get('x-muzika-key') !== env.MUZIKA_KEY) {
      return new Response('Forbidden', { status: 403 });
    }

    const match = url.pathname.match(/^\/youtubei\/v1\/(.+)$/);
    const endpoint = match?.[1];
    if (!endpoint || !ALLOWED.has(endpoint)) {
      return new Response('Not found', { status: 404 });
    }

    const body = await request.text();
    if (body.length > 64 * 1024) {
      return new Response('Payload too large', { status: 413 });
    }

    const headers = new Headers();
    for (const h of ['accept-language', 'x-goog-visitor-id']) {
      const v = request.headers.get(h);
      if (v) headers.set(h, v);
    }
    return relay(env).fetch(`https://relay/youtubei/v1/${endpoint}`, {
      method: 'POST',
      headers,
      body,
    });
  },
};
