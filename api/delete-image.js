export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const { publicId } = req.body || {};
  if (!publicId) return res.status(400).json({ error: 'Missing publicId' });

  const apiKey = process.env.CLOUDINARY_API_KEY;
  const apiSecret = process.env.CLOUDINARY_API_SECRET;
  if (!apiKey || !apiSecret) return res.status(500).json({ error: 'Cloudinary credentials not configured' });

  const creds = Buffer.from(`${apiKey}:${apiSecret}`).toString('base64');
  const url = `https://api.cloudinary.com/v1_1/dhk87y1nb/resources/image/upload?public_ids[]=${encodeURIComponent(publicId)}`;

  try {
    const r = await fetch(url, { method: 'DELETE', headers: { Authorization: `Basic ${creds}` } });
    const data = await r.json();
    res.status(r.ok ? 200 : 400).json(data);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
}
