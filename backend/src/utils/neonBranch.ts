/**
 * Neon API utilities — creates and deletes per-academy database branches.
 * Each tuition academy gets an isolated Neon branch named {slug}_DB.
 *
 * Required env vars:
 *   NEON_API_KEY     — Project-scoped API key from console.neon.tech
 *   NEON_PROJECT_ID  — Found in the Neon project URL
 */

const NEON_API = 'https://console.neon.tech/api/v2';

function apiKey(): string {
  const k = process.env.NEON_API_KEY;
  if (!k) throw new Error('NEON_API_KEY is not configured');
  return k;
}

function projectId(): string {
  const p = process.env.NEON_PROJECT_ID;
  if (!p) throw new Error('NEON_PROJECT_ID is not configured');
  return p;
}

interface NeonHeaders { [key: string]: string }
function headers(): NeonHeaders {
  return {
    Authorization: `Bearer ${apiKey()}`,
    'Content-Type': 'application/json',
    Accept: 'application/json',
  };
}

export interface BranchResult {
  branchId: string;
  connectionString: string;
}

/**
 * Create a new Neon branch for an academy.
 * Branch name: {slug}_DB  e.g. "sunshine_tuition_DB"
 */
export async function createAcademyBranch(slug: string): Promise<BranchResult> {
  const pid = projectId();
  const branchName = `${slug}_DB`;

  // 1 — Create branch + endpoint
  const createRes = await fetch(`${NEON_API}/projects/${pid}/branches`, {
    method: 'POST',
    headers: headers(),
    body: JSON.stringify({
      branch: { name: branchName },
      endpoints: [{ type: 'read_write' }],
    }),
    signal: AbortSignal.timeout(30_000),
  });

  if (!createRes.ok) {
    const body = await createRes.text();
    throw new Error(`Neon branch creation failed (${createRes.status}): ${body}`);
  }

  const created = await createRes.json() as {
    branch: { id: string };
    connection_uris?: Array<{ connection_uri: string }>;
  };

  const branchId = created.branch.id;

  // 2 — Use inline connection URI if provided, otherwise fetch separately
  if (created.connection_uris?.length) {
    return { branchId, connectionString: created.connection_uris[0].connection_uri };
  }

  // Fallback: resolve role + db names from project defaults, then fetch URI
  const [rolesRes, dbsRes] = await Promise.all([
    fetch(`${NEON_API}/projects/${pid}/roles`, { headers: headers(), signal: AbortSignal.timeout(15_000) }),
    fetch(`${NEON_API}/projects/${pid}/databases`, { headers: headers(), signal: AbortSignal.timeout(15_000) }),
  ]);

  const rolesData = await rolesRes.json() as { roles: Array<{ name: string }> };
  const dbsData   = await dbsRes.json() as { databases: Array<{ name: string }> };

  const roleName = rolesData.roles.find(r => !r.name.includes('superuser'))?.name ?? 'neondb_owner';
  const dbName   = dbsData.databases[0]?.name ?? 'neondb';

  const uriRes = await fetch(
    `${NEON_API}/projects/${pid}/connection_uri?branch_id=${branchId}&role_name=${roleName}&database_name=${dbName}`,
    { headers: headers(), signal: AbortSignal.timeout(15_000) }
  );

  if (!uriRes.ok) {
    const body = await uriRes.text();
    throw new Error(`Failed to get connection URI (${uriRes.status}): ${body}`);
  }

  const uriData = await uriRes.json() as { uri: string };
  return { branchId, connectionString: uriData.uri };
}

/**
 * Delete an academy's Neon branch (used when academy is permanently removed).
 */
export async function deleteAcademyBranch(branchId: string): Promise<void> {
  const pid = projectId();
  await fetch(`${NEON_API}/projects/${pid}/branches/${branchId}`, {
    method: 'DELETE',
    headers: headers(),
    signal: AbortSignal.timeout(15_000),
  });
}
