const HYDRA_ADMIN = 'http://hydra-admin.infra.svc.cluster.local:4445';
const HYDRA_PUBLIC = 'http://hydra-public.infra.svc.cluster.local:4444';
const CLIENT_ID = 'grafana';
const CLIENT_SECRET = 'wBmx6MQKdyPFHkcq97AUE8NXtCWSplOe';
const SUBJECT = '12a9aecc-68ae-461c-850e-90920b377a19';
const REDIRECT_URI = 'https://grafana.ecoma.io/login/generic_oauth';

// Simple cookie jar
let cookies = {};
function extractCookies(resp) {
  const setCookie = resp.headers.getSetCookie?.() || [];
  for (const c of setCookie) {
    const [kv] = c.split(';');
    const [k, v] = kv.split('=');
    cookies[k.trim()] = v.trim();
  }
}
function cookieHeader() {
  return Object.entries(cookies).map(([k,v]) => `${k}=${v}`).join('; ');
}

async function main() {
  // Step 1: Initiate auth (capture CSRF cookies)
  console.log('=== Step 1: Initiate auth request ===');
  const authUrl = `${HYDRA_PUBLIC}/oauth2/auth?client_id=${CLIENT_ID}&response_type=code&scope=openid+email+profile+offline_access&redirect_uri=${encodeURIComponent(REDIRECT_URI)}&state=randomstatevalue123456789`;
  const authResp = await fetch(authUrl, { redirect: 'manual' });
  extractCookies(authResp);
  const location1 = authResp.headers.get('location');
  console.log('Cookies after step 1:', JSON.stringify(cookies));

  const loginChallenge = new URL(location1).searchParams.get('login_challenge');
  console.log('Login challenge:', loginChallenge ? 'OK' : 'MISSING');

  // Step 2: Accept login via admin
  console.log('\n=== Step 2: Accept login ===');
  const acceptLoginResp = await fetch(
    `${HYDRA_ADMIN}/admin/oauth2/auth/requests/login/accept?login_challenge=${loginChallenge}`,
    {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ subject: SUBJECT, remember: false }),
    }
  );
  const acceptLogin = await acceptLoginResp.json();
  const redirect1 = acceptLogin.redirect_to.replace('https://oauth.ecoma.io', HYDRA_PUBLIC);
  console.log('Redirect to:', redirect1.substring(0, 80) + '...');

  // Step 3: Follow redirect WITH cookies
  console.log('\n=== Step 3: Follow redirect to consent (with cookies) ===');
  const consentResp = await fetch(redirect1, {
    redirect: 'manual',
    headers: { Cookie: cookieHeader() },
  });
  extractCookies(consentResp);
  const location2 = consentResp.headers.get('location');
  console.log('Location:', location2);
  console.log('Cookies after step 3:', JSON.stringify(cookies));

  let code;
  const url2 = new URL(location2);
  const consentChallenge = url2.searchParams.get('consent_challenge');
  code = url2.searchParams.get('code');
  console.log('Consent challenge:', consentChallenge);
  console.log('Code:', code);

  if (consentChallenge && !code) {
    console.log('\n=== Step 4: Accept consent ===');
    const acceptConsentResp = await fetch(
      `${HYDRA_ADMIN}/admin/oauth2/auth/requests/consent/accept?consent_challenge=${consentChallenge}`,
      {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          grant_scope: ['openid', 'email', 'profile', 'offline_access'],
          grant_access_token_audience: [],
          session: { id_token: { email: 'admin@ecoma.io', email_verified: false, preferred_username: 'admin', updated_at: 1775855444 }, access_token: {} },
        }),
      }
    );
    const acceptConsent = await acceptConsentResp.json();
    console.log('Accept consent:', JSON.stringify(acceptConsent).substring(0, 200));
    const redirect2 = acceptConsent.redirect_to.replace('https://oauth.ecoma.io', HYDRA_PUBLIC);

    const codeResp = await fetch(redirect2, {
      redirect: 'manual',
      headers: { Cookie: cookieHeader() },
    });
    extractCookies(codeResp);
    const location3 = codeResp.headers.get('location');
    console.log('Final redirect:', location3);
    code = new URL(location3).searchParams.get('code');
  }

  if (!code) {
    console.log('FAILED: No authorization code');
    return;
  }
  console.log('\nAuthorization code:', code);

  // Step 5: Exchange code for tokens
  console.log('\n=== Step 5: Exchange code for tokens ===');
  const tokenResp = await fetch(`${HYDRA_PUBLIC}/oauth2/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: REDIRECT_URI,
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
    }),
  });
  const tokenData = await tokenResp.json();
  if (tokenData.error) {
    console.log('Token ERROR:', JSON.stringify(tokenData));
    return;
  }
  console.log('Token response keys:', Object.keys(tokenData));
  console.log('Token type:', tokenData.token_type);
  console.log('Scope:', tokenData.scope);

  // Step 6: Call /userinfo
  console.log('\n=== Step 6: /userinfo response ===');
  const userinfoResp = await fetch(`${HYDRA_PUBLIC}/userinfo`, {
    headers: { Authorization: `Bearer ${tokenData.access_token}` },
  });
  const userinfo = await userinfoResp.json();
  console.log(JSON.stringify(userinfo, null, 2));

  // Step 7: Decode JWT access token
  console.log('\n=== Step 7: Access token JWT payload ===');
  const jwtParts = tokenData.access_token.split('.');
  if (jwtParts.length === 3) {
    const payload = JSON.parse(Buffer.from(jwtParts[1], 'base64url').toString());
    console.log(JSON.stringify(payload, null, 2));
  }

  // Step 8: Decode ID token  
  console.log('\n=== Step 8: ID token payload ===');
  if (tokenData.id_token) {
    const idParts = tokenData.id_token.split('.');
    if (idParts.length === 3) {
      const payload = JSON.parse(Buffer.from(idParts[1], 'base64url').toString());
      console.log(JSON.stringify(payload, null, 2));
    }
  }
}

main().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
