-- MAKELTYX360 — Compteur public des commandes du jour + verrouillage des données clients
-- À exécuter une seule fois dans Supabase > SQL Editor (projet orepdnfhcmckyiclbnlq).
-- Le script peut être relancé sans risque.

-- 1) Compteur public : renvoie UNIQUEMENT un nombre (aucun nom, téléphone ni détail de commande).
create or replace function public.orders_today_count()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.orders
  where (created_at at time zone 'Africa/Algiers')::date
      = (now() at time zone 'Africa/Algiers')::date;
$$;

revoke all on function public.orders_today_count() from public;
grant execute on function public.orders_today_count() to anon, authenticated;

-- 2) Protection des données personnelles : aucune lecture directe des commandes par un visiteur anonyme.
--    Les commandes passent par la fonction place_order ; l'admin lit via son rôle "authenticated".
--    Par sécurité, on ne touche aux droits que si place_order est en SECURITY DEFINER
--    (sinon on pourrait bloquer l'enregistrement des commandes) : un avertissement s'affiche alors.
do $$
declare
  definer boolean;
begin
  select bool_and(p.prosecdef) into definer
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.proname = 'place_order';

  if definer then
    revoke select, update, delete on public.orders, public.order_items, public.order_status_history from anon;
    raise notice 'OK : tables de commandes verrouillées pour les visiteurs anonymes.';
  else
    raise warning 'place_order n''est pas SECURITY DEFINER : droits anonymes laissés inchangés. Vérifiez manuellement les politiques RLS de orders, order_items et order_status_history.';
  end if;
end $$;

-- 3) Vérification : le compteur doit renvoyer un nombre, et anon ne doit plus pouvoir lire les commandes.
select public.orders_today_count() as commandes_du_jour,
       has_table_privilege('anon', 'public.orders', 'select') as anon_peut_lire_orders,
       has_table_privilege('anon', 'public.order_items', 'select') as anon_peut_lire_items;
