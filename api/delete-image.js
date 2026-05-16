// 사진(또는 영상) 미디어 삭제: 인증 → 오너십 검증 → Cloudinary 삭제 → DB 삭제
// publicId 없으면 Cloudinary 단계 skip (유튜브용)
export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const authHeader = req.headers.authorization || '';
  const token = authHeader.replace(/^Bearer\s+/i, '');
  if (!token) return res.status(401).json({ error: 'Unauthorized' });

  const SUPABASE_URL = 'https://mspwdasiewqtwfyngdhy.supabase.co';
  const SUPABASE_ANON_KEY = 'sb_publishable_VhU_zhguD5UkIaMqGdLQCQ_cBjQI3yG';

  // 1) JWT 검증
  const userResp = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` }
  });
  if (!userResp.ok) return res.status(401).json({ error: 'Invalid token' });
  const user = await userResp.json();
  const myName = user?.user_metadata?.name || '';

  const { dbId, publicId } = req.body || {};
  if (!dbId || !Number.isInteger(dbId)) return res.status(400).json({ error: 'Missing or invalid dbId' });
  if (publicId && !/^[\w\-/]+$/.test(publicId)) return res.status(400).json({ error: 'Invalid publicId' });

  // 2) DB 조회: 해당 row가 존재하고 본인 소유인지
  const rowResp = await fetch(
    `${SUPABASE_URL}/rest/v1/photo_memories?id=eq.${dbId}&select=id,uploaded_by,src,type`,
    { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` } }
  );
  if (!rowResp.ok) return res.status(500).json({ error: 'DB lookup failed' });
  const rows = await rowResp.json();
  if (!rows.length) return res.status(404).json({ error: 'Not found' });
  const row = rows[0];
  if (row.uploaded_by && row.uploaded_by !== myName) {
    return res.status(403).json({ error: 'Not your media' });
  }

  // 3) Cloudinary 삭제 (사진인 경우만)
  if (publicId) {
    const apiKey = process.env.CLOUDINARY_API_KEY;
    const apiSecret = process.env.CLOUDINARY_API_SECRET;
    if (apiKey && apiSecret) {
      const creds = Buffer.from(`${apiKey}:${apiSecret}`).toString('base64');
      const cdUrl = `https://api.cloudinary.com/v1_1/dhk87y1nb/resources/image/upload?public_ids[]=${encodeURIComponent(publicId)}`;
      try {
        await fetch(cdUrl, { method: 'DELETE', headers: { Authorization: `Basic ${creds}` } });
      } catch (e) {
        // Cloudinary 실패해도 DB 삭제는 진행 (orphan만 남음 - 허용)
        console.warn('Cloudinary delete failed:', e?.message);
      }
    }
  }

  // 4) DB 삭제
  const delResp = await fetch(
    `${SUPABASE_URL}/rest/v1/photo_memories?id=eq.${dbId}`,
    { method: 'DELETE', headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` } }
  );
  if (!delResp.ok) return res.status(500).json({ error: 'DB delete failed' });

  res.status(200).json({ ok: true });
}
