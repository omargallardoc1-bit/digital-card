import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const authHeader = req.headers.get("Authorization") || "";
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const auth = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
    const { data: { user } } = await auth.auth.getUser();
    if (!user) return json({ error: "Unauthorized" }, 401);
    const { appointment_id, action } = await req.json();
    if (!appointment_id || !["confirm","reject","cancel"].includes(action)) return json({ error: "Invalid request" }, 400);
    const admin = createClient(url, service);
    const { data: appt } = await admin.from("appointments").select("id,organization_id,card_id,status").eq("id", appointment_id).maybeSingle();
    if (!appt) return json({ error: "Appointment not found" }, 404);
    const { data: member } = await admin.from("organization_members").select("id").eq("organization_id", appt.organization_id).eq("user_id", user.id).maybeSingle();
    const { data: owned } = await admin.from("digital_cards").select("id").eq("id", appt.card_id).eq("owner_id", user.id).maybeSingle();
    if (!member && !owned) return json({ error: "Forbidden" }, 403);
    const now = new Date().toISOString();
    const patch:any = { updated_at: now };
    if (action === "confirm") Object.assign(patch,{status:"confirmed",confirmed_at:now,cancelled_at:null});
    else Object.assign(patch,{status:action === "reject" ? "rejected" : "cancelled",cancelled_at:now});
    const { data, error } = await admin.from("appointments").update(patch).eq("id", appointment_id).select("id,status,confirmed_at,cancelled_at,scheduled_at,duration_minutes").single();
    if (error) throw error;
    return json({ appointment:data },200);
  } catch (e) { return json({ error:e instanceof Error ? e.message : "Unexpected error" },500); }
});
function json(body:unknown,status:number){return new Response(JSON.stringify(body),{status,headers:{...corsHeaders,"Content-Type":"application/json"}})}
