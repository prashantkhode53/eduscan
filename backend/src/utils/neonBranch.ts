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
    signal: AbortSignal.timeout(60_000),
  });

  if (!createRes.ok) {
    const body = await createRes.text();
    throw new Error(`Neon branch creation failed (${createRes.status}): ${body}`);
  }

  const created = await createRes.json() as {
    branch: { id: string };
    endpoints?: Array<{ host: string }>;
    connection_uris?: Array<{ connection_uri: string }>;
  };

  const branchId = created.branch.id;
  console.log(`[Neon] Branch created: ${branchId} (${branchName})`);

  // Option A — use connection_uris bundled in the create response (Neon v2 default)
  if (created.connection_uris?.length) {
    console.log('[Neon] Using inline connection_uri');
    return { branchId, connectionString: created.connection_uris[0].connection_uri };
  }

  // Option B — derive connection string by swapping host in DATABASE_URL.
  // Neon branches inherit the same role/password/database from the parent,
  // so only the endpoint hostname differs.
  const parentUrl = process.env.DATABASE_URL;
  if (parentUrl && created.endpoints?.length) {
    const newHost = created.endpoints[0].host;
    const connectionString = _swapHost(parentUrl, newHost);
    console.log(`[Neon] Derived connection string via host swap → ${newHost}`);
    return { branchId, connectionString };
  }

  // Option C — call connection_uri API with main branch role/db names
  // Get the main branch id first
  const branchesRes = await fetch(
    `${NEON_API}/projects/${pid}/branches`,
    { headers: headers(), signal: AbortSignal.timeout(15_000) }
  );
  if (branchesRes.ok) {
    const branchesData = await branchesRes.json() as {
      branches: Array<{ id: string; name: string; primary: boolean }>
    };
    const mainBranch = branchesData.branches.find(b => b.primary || b.name === 'main');
    if (mainBranch) {
      // Get roles on main branch
      const rolesRes = await fetch(
        `${NEON_API}/projects/${pid}/branches/${mainBranch.id}/roles`,
        { headers: headers(), signal: AbortSignal.timeout(15_000) }
      );
      const dbsRes = await fetch(
        `${NEON_API}/projects/${pid}/branches/${mainBranch.id}/databases`,
        { headers: headers(), signal: AbortSignal.timeout(15_000) }
      );
      if (rolesRes.ok && dbsRes.ok) {
        const rolesData = await rolesRes.json() as { roles: Array<{ name: string }> };
        const dbsData   = await dbsRes.json() as { databases: Array<{ name: string }> };
        const roleName  = rolesData.roles.find(r => !r.name.includes('superuser'))?.name ?? 'neondb_owner';
        const dbName    = dbsData.databases[0]?.name ?? 'neondb';

        const uriRes = await fetch(
          `${NEON_API}/projects/${pid}/connection_uri?branch_id=${branchId}&role_name=${roleName}&database_name=${dbName}`,
          { headers: headers(), signal: AbortSignal.timeout(15_000) }
        );
        if (uriRes.ok) {
          const uriData = await uriRes.json() as { uri: string };
          console.log('[Neon] Connection URI fetched via API');
          return { branchId, connectionString: uriData.uri };
        }
      }
    }
  }

  throw new Error(
    'Could not get connection string for new Neon branch. ' +
    'Ensure DATABASE_URL and NEON_API_KEY are set correctly on Render.'
  );
}

/** Replace the hostname in a postgres connection URL, keeping everything else. */
function _swapHost(url: string, newHost: string): string {
  // postgresql://user:pass@old-host.neon.tech/dbname?sslmode=require
  return url.replace(/@([^/]+)\//, `@${newHost}/`);
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
