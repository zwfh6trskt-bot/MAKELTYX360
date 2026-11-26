-- =====================================================================
-- MAKELTYX360 — Base Neon (Neon Auth + Data API)
-- Sécurité dans la base : un visiteur ne peut que lire les produits,
-- passer une commande et lire le NOMBRE de commandes du jour.
-- Les données clients ne sont lisibles que par un compte présent dans public.admins.
-- =====================================================================

-- ---------- Tables ----------------------------------------------------
create table if not exists public.settings (
  id        boolean primary key default true check (id),
  open_min  int not null default 480 check (open_min between 0 and 1439),   -- 08h00
  close_min int not null default 720 check (close_min between 1 and 1440),  -- 12h00
  goal      int not null default 10,                                         -- seuil livraison gratuite
  extra_date date,                 -- jour exceptionnel (heure d'Alger)
  extra_close_min int check (extra_close_min between 1 and 1440)  -- fermeture ce jour-là
);
insert into public.settings default values on conflict do nothing;

create table if not exists public.products (
  id     text primary key,
  name   text not null,
  price  int  not null check (price >= 0),
  active boolean not null default true,
  sort   int  not null default 0
);

create table if not exists public.orders (
  id         uuid primary key default gen_random_uuid(),
  number     text not null unique,
  first_name text not null,
  last_name  text not null,
  phone      text not null,
  status     text not null default 'nouvelle'
             check (status in ('nouvelle','vue','en_preparation','prete','recuperee')),
  total      int  not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists orders_created_idx on public.orders (created_at desc);

create table if not exists public.order_items (
  id         bigint generated always as identity primary key,
  order_id   uuid not null references public.orders(id) on delete cascade,
  product_id text,
  name       text not null,
  qty        int  not null check (qty between 1 and 20),
  unit_price int  not null
);
create index if not exists order_items_order_idx on public.order_items (order_id);

create table if not exists public.order_status_history (
  id         bigint generated always as identity primary key,
  order_id   uuid not null references public.orders(id) on delete cascade,
  status     text not null,
  changed_at timestamptz not null default now()
);
create index if not exists osh_order_idx on public.order_status_history (order_id);

-- Comptes autorisés à l'administration (géré en SQL uniquement, jamais via l'API).
create table if not exists public.admins (email text primary key check (email = lower(email)));

-- ---------- Historique automatique des statuts -------------------------
create or replace function public.log_order_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.order_status_history(order_id, status) values (new.id, new.status);
  end if;
  return new;
end $$;
drop trigger if exists orders_status_log on public.orders;
create trigger orders_status_log after insert or update of status on public.orders
  for each row execute function public.log_order_status();

-- ---------- Fonctions -------------------------------------------------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from neon_auth."user" u join public.admins a on a.email = lower(u.email)
    where u.id::text = auth.user_id()::text);
$$;

-- Fermeture du jour : exceptionnelle si extra_date = aujourd'hui, sinon close_min.
create or replace function public.close_min_today() returns int
language sql stable security definer set search_path = public as $$
  select case when extra_date = (now() at time zone 'Africa/Algiers')::date and extra_close_min is not null
              then extra_close_min else close_min end from public.settings;
$$;

create or replace function public.shop_status() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('now', now(), 'open_min', open_min, 'close_min', public.close_min_today()) from public.settings;
$$;

-- Compteur public : renvoie UNIQUEMENT un nombre.
create or replace function public.orders_today_count() returns integer
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.orders
  where (created_at at time zone 'Africa/Algiers')::date = (now() at time zone 'Africa/Algiers')::date;
$$;

create or replace function public.place_order(p_first text, p_last text, p_phone text, p_items jsonb)
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  s public.settings; m int; d date; n int; num text; oid uuid; tot int := 0; it jsonb; pr public.products; q int; cnt int := 0;
begin
  select * into s from public.settings;
  m := extract(hour from now() at time zone 'Africa/Algiers')::int * 60 + extract(minute from now() at time zone 'Africa/Algiers')::int;
  if m < s.open_min or m >= public.close_min_today() then raise exception 'SHOP_CLOSED'; end if;

  p_first := btrim(coalesce(p_first,'')); p_last := btrim(coalesce(p_last,''));
  p_phone := regexp_replace(coalesce(p_phone,''), '[\s.-]', '', 'g');
  if length(p_first) not between 2 and 60 or length(p_last) not between 2 and 60 then raise exception 'INVALID_NAME'; end if;
  if p_phone !~ '^(0|\+213)[567][0-9]{8}$' then raise exception 'INVALID_PHONE'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 30 then raise exception 'INVALID_ITEMS'; end if;

  d := (now() at time zone 'Africa/Algiers')::date;
  perform pg_advisory_xact_lock(hashtext('makeltyx_order_number'));
  select count(*) + 1 into n from public.orders where (created_at at time zone 'Africa/Algiers')::date = d;
  num := 'M' || lpad(n::text, 3, '0');
  while exists (select 1 from public.orders where number = num) loop
    n := n + 1; num := 'M' || lpad(n::text, 3, '0') || '-' || to_char(d, 'DDMM');
  end loop;

  insert into public.orders(number, first_name, last_name, phone) values (num, p_first, p_last, p_phone) returning id into oid;
  for it in select * from jsonb_array_elements(p_items) loop
    q := (it->>'qty')::int;
    select * into pr from public.products where id = it->>'id' and active;
    if pr.id is null or q is null or q not between 1 and 20 then raise exception 'INVALID_ITEMS'; end if;
    insert into public.order_items(order_id, product_id, name, qty, unit_price) values (oid, pr.id, pr.name, q, pr.price);
    tot := tot + q * pr.price; cnt := cnt + q;
  end loop;
  if cnt > 60 then raise exception 'INVALID_ITEMS'; end if;
  update public.orders set total = tot where id = oid;
  return num;
end $$;

-- ---------- Droits + RLS -----------------------------------------------
revoke all on all tables in schema public from anonymous, authenticated;
revoke all on all functions in schema public from public, anonymous, authenticated;

alter table public.settings enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_status_history enable row level security;
alter table public.admins enable row level security;

drop policy if exists products_read on public.products;
create policy products_read on public.products for select using (true);
grant select on public.products to anonymous, authenticated;

drop policy if exists orders_admin_read on public.orders;
drop policy if exists orders_admin_upd on public.orders;
create policy orders_admin_read on public.orders for select to authenticated using (public.is_admin());
create policy orders_admin_upd  on public.orders for update to authenticated using (public.is_admin()) with check (public.is_admin());
grant select on public.orders to authenticated;
grant update (status) on public.orders to authenticated;

drop policy if exists items_admin_read on public.order_items;
create policy items_admin_read on public.order_items for select to authenticated using (public.is_admin());
grant select on public.order_items to authenticated;

drop policy if exists hist_admin_read on public.order_status_history;
create policy hist_admin_read on public.order_status_history for select to authenticated using (public.is_admin());
grant select on public.order_status_history to authenticated;

grant execute on function public.shop_status(), public.orders_today_count(),
  public.place_order(text, text, text, jsonb) to anonymous, authenticated;
grant execute on function public.is_admin() to authenticated;
