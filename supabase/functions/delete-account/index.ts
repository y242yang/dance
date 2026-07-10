// Deletes the calling user's own account. Required for App Store Guideline
// 5.1.1(v): apps with account creation must let users delete their account
// from within the app.
//
// This can't be done client-side with the anon key -- auth.admin.deleteUser
// requires the service role key, which must never ship in the app. So this
// runs server-side: it verifies who the caller actually is from their own
// session token (never trusts a client-supplied user id), then uses the
// service role only to delete that verified caller's own account.
//
// Deleting the auth.users row cascades automatically: auth.users -> profiles
// (ON DELETE CASCADE) -> follows / saved_classes / log_entries (ON DELETE
// CASCADE from profiles). Nothing else needs to be deleted manually.
//
// SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are injected
// automatically into every Edge Function -- no manual secret setup needed.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing Authorization header" }), { status: 401 });
    }

    // Scoped to the caller's own JWT -- used only to verify who they are.
    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) {
      return new Response(JSON.stringify({ error: "Invalid or expired session" }), { status: 401 });
    }

    // Service role -- only used to delete the now-verified caller's own account
    // and their own storage files.
    const adminClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Storage objects aren't covered by the profiles/auth.users FK cascade, so
    // the avatar has to be removed explicitly. Best-effort: a user who never
    // uploaded one will just get a harmless "not found"-style empty result.
    await adminClient.storage.from("avatars").remove([`${user.id}/avatar.jpg`]);

    const { error: deleteError } = await adminClient.auth.admin.deleteUser(user.id);
    if (deleteError) {
      return new Response(JSON.stringify({ error: deleteError.message }), { status: 500 });
    }

    return new Response(JSON.stringify({ success: true }), { status: 200 });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
