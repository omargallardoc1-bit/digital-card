import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...corsHeaders,"Content-Type":"application/json"}});

Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS") return new Response("ok",{headers:corsHeaders});
 if(req.method!=="POST") return json({error:"Method not allowed"},405);
 try{
  const authHeader=req.headers.get("Authorization")||"";
  const url=Deno.env.get("SUPABASE_URL")!;
  const anon=Deno.env.get("SUPABASE_ANON_KEY")!;
  const service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth=createClient(url,anon,{global:{headers:{Authorization:authHeader}}});
  const {data:{user},error:authError}=await auth.auth.getUser();
  if(authError||!user) return json({error:"Unauthorized"},401);

  const {appointment_id,action}=await req.json();
  if(!appointment_id||!["confirm","reject","cancel"].includes(action)) return json({error:"Invalid request"},400);

  const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:appt,error:appointmentError}=await admin.from("appointments").select("id,organization_id,card_id,status,scheduled_at,duration_minutes").eq("id",appointment_id).maybeSingle();
  if(appointmentError) throw appointmentError;
  if(!appt) return json({error:"Appointment not found"},404);

  const {data:owned,error:ownerError}=await admin.from("digital_cards").select("id").eq("id",appt.card_id).eq("owner_id",user.id).maybeSingle();
  if(ownerError) throw ownerError;

  let authorized=Boolean(owned);
  if(!authorized){
    const {data:member,error:memberError}=await admin.from("organization_members").select("role").eq("organization_id",appt.organization_id).eq("user_id",user.id).maybeSingle();
    if(memberError) throw memberError;
    authorized=["owner","admin"].includes(String(member?.role||"").toLowerCase());
  }
  if(!authorized) return json({error:"Forbidden"},403);

  if(action==="confirm"&&appt.status!=="requested") return json({error:"Only requested appointments can be confirmed"},409);
  if(["reject","cancel"].includes(action)&&!["requested","confirmed","rescheduled"].includes(appt.status)) return json({error:"Appointment cannot be cancelled from its current state"},409);

  const now=new Date().toISOString();
  const patch=action==="confirm"?{status:"confirmed",confirmed_at:now,cancelled_at:null,updated_at:now}:{status:"cancelled",cancelled_at:now,updated_at:now};
  const {data,error}=await admin.from("appointments").update(patch).eq("id",appointment_id).select("id,status,confirmed_at,cancelled_at,scheduled_at,duration_minutes").single();
  if(error) throw error;
  return json({appointment:data});
 }catch(e){return json({error:e instanceof Error?e.message:"Unexpected error"},500)}
});
