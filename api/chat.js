export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Method Not Allowed" });
  }

  const body =
    typeof req.body === "string" ? JSON.parse(req.body || "{}") : req.body || {};
  const { prompt, query } = body;

  if (!prompt || typeof prompt !== "string") {
    return res.status(400).json({ error: "prompt is required" });
  }

  if (!process.env.CLAUDE_API_KEY) {
    return res.status(500).json({ error: "Server is missing CLAUDE_API_KEY" });
  }

  let userId = null;
  const authHeader = req.headers.authorization || "";

  if (authHeader.startsWith("Bearer ") && process.env.SUPABASE_URL && process.env.SUPABASE_ANON_KEY) {
    const token = authHeader.slice(7);
    try {
      const userRes = await fetch(`${process.env.SUPABASE_URL}/auth/v1/user`, {
        headers: {
          apikey: process.env.SUPABASE_ANON_KEY,
          Authorization: `Bearer ${token}`,
        },
      });

      if (userRes.ok) {
        const userData = await userRes.json();
        userId = userData.id || null;
      }
    } catch (error) {
      console.error("JWT verify error:", error?.message || error);
    }
  }

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": process.env.CLAUDE_API_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: "claude-haiku-4-5-20251001",
      max_tokens: 150,
      temperature: 0.1,
      messages: [{ role: "user", content: prompt }],
    }),
  });

  const data = await response.json();

  if (!response.ok || data.error) {
    const errorMessage = data?.error?.message || "Anthropic API error";
    return res.status(500).json({ error: errorMessage });
  }

  if (process.env.SUPABASE_URL && process.env.SUPABASE_ANON_KEY && query) {
    const logAuthHeader = authHeader.startsWith("Bearer ")
      ? authHeader
      : `Bearer ${process.env.SUPABASE_ANON_KEY}`;

    fetch(`${process.env.SUPABASE_URL}/rest/v1/queries`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: process.env.SUPABASE_ANON_KEY,
        Authorization: logAuthHeader,
        Prefer: "return=minimal",
      },
      body: JSON.stringify({ user_id: userId, query }),
    }).catch((error) => console.error("Query log error:", error?.message || error));
  }

  return res.status(200).json({ text: data?.content?.[0]?.text || "" });
}
