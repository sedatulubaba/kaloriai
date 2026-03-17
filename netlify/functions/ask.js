exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method Not Allowed' };
  }

  const { prompt, query } = JSON.parse(event.body);

  const response = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': process.env.CLAUDE_API_KEY,
      'anthropic-version': '2023-06-01'
    },
    body: JSON.stringify({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: 150,
      temperature: 0.1,
      messages: [{ role: 'user', content: prompt }]
    })
  });

  const data = await response.json();

  if (data.error) {
    return { statusCode: 500, body: JSON.stringify({ error: data.error.message }) };
  }

  // Supabase'e log at
  try {
    const logRes = await fetch(`${process.env.SUPABASE_URL}/rest/v1/logs`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': process.env.SUPABASE_ANON_KEY,
        'Authorization': `Bearer ${process.env.SUPABASE_ANON_KEY}`,
        'Prefer': 'return=minimal'
      },
      body: JSON.stringify({ query })
    });
    if (!logRes.ok) {
      const err = await logRes.text();
      console.error('Supabase log hatası:', err);
    }
  } catch (e) {
    console.error('Supabase bağlantı hatası:', e.message);
  }

  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text: data.content[0].text })
  };
};
