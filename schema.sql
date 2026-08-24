-- =====================================================================
--  Agendamento de massagem · CIO Cerrado Experience 2026
--  Banco de dados (Supabase / PostgreSQL) — rode este arquivo inteiro
--  uma vez no SQL Editor do Supabase. Cria tabelas, regras de acesso,
--  as funções de reserva atômica e já carrega os horários (Opção 1).
-- =====================================================================

create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------
-- TABELAS
-- ----------------------------------------------------------------------
create table if not exists public.slots (
  id         bigint generated always as identity primary key,
  slot_key   text unique not null,     -- ex.: 'd13-0830'
  day_id     text not null,            -- 'd13'
  date_label text not null,            -- '13 ago'
  weekday    text not null,            -- 'qui'
  starts     text not null,            -- '08:30'
  ends       text not null,            -- '09:05'
  capacity   int  not null check (capacity > 0),
  position   int  not null default 0   -- ordem de exibição
);

-- quem pode agendar (lista de e-mails autorizados)
create table if not exists public.allowlist (
  email text primary key
);

-- quem pode abrir a área administrativa / relatório
create table if not exists public.admins (
  email text primary key
);

create table if not exists public.reservations (
  id             uuid primary key default gen_random_uuid(),
  slot_id        bigint not null references public.slots(id),
  email          text not null,
  name           text not null,
  phone          text not null,
  birth          date,
  pregnant       text,
  surgery        text,
  surgery_detail text,
  medium         text,          -- Óleo / Creme
  intensity      text,          -- Leve / Moderada / Intensa
  status         text not null default 'active',   -- active | cancelled
  manage_token   uuid not null default gen_random_uuid() unique,
  created_at     timestamptz not null default now()
);

-- no máximo UMA reserva ativa por e-mail
create unique index if not exists reservations_one_active_per_email
  on public.reservations (lower(email)) where status = 'active';

create index if not exists reservations_slot_active
  on public.reservations (slot_id) where status = 'active';

-- ----------------------------------------------------------------------
-- SEGURANÇA (RLS)
--   * ninguém acessa a tabela de reservas diretamente pelo app público.
--   * o agendamento acontece só pelas funções abaixo (SECURITY DEFINER).
--   * o relatório só é lido por quem está logado E está em 'admins'.
-- ----------------------------------------------------------------------
alter table public.slots         enable row level security;
alter table public.reservations  enable row level security;
alter table public.allowlist     enable row level security;
alter table public.admins        enable row level security;

-- admin autenticado lê as reservas
drop policy if exists res_admin_read on public.reservations;
create policy res_admin_read on public.reservations
  for select to authenticated
  using (exists (select 1 from public.admins a
                 where a.email = lower(auth.jwt() ->> 'email')));

-- admin autenticado lê os horários (para o relatório)
drop policy if exists slots_admin_read on public.slots;
create policy slots_admin_read on public.slots
  for select to authenticated using (true);

-- ----------------------------------------------------------------------
-- FUNÇÕES
-- ----------------------------------------------------------------------

-- Verifica se o e-mail pode agendar.
-- (Para liberar por DOMÍNIO em vez de e-mail exato, veja a nota no README.)
create or replace function public.check_access(p_email text)
returns boolean language sql security definer set search_path = public as $$
  select exists (select 1 from allowlist where lower(email) = lower(p_email));
$$;

-- Lista os horários com o número de vagas livres (sem expor quem reservou).
create or replace function public.list_availability()
returns table (id bigint, slot_key text, day_id text, date_label text,
               weekday text, starts text, ends text, capacity int, free int)
language sql security definer set search_path = public as $$
  select s.id, s.slot_key, s.day_id, s.date_label, s.weekday, s.starts, s.ends,
         s.capacity,
         s.capacity - coalesce(count(r.*) filter (where r.status = 'active'), 0)::int as free
  from slots s
  left join reservations r on r.slot_id = s.id
  group by s.id
  order by s.position;
$$;

-- Cria a reserva de forma ATÔMICA (trava o horário, confere a vaga, insere).
create or replace function public.reserve(
  p_email text, p_name text, p_phone text, p_birth date,
  p_pregnant text, p_surgery text, p_surgery_detail text,
  p_medium text, p_intensity text, p_slot_id bigint)
returns public.reservations
language plpgsql security definer set search_path = public as $$
declare
  v_cap  int;
  v_used int;
  v_row  public.reservations;
begin
  if not exists (select 1 from allowlist where lower(email) = lower(p_email)) then
    raise exception 'NOT_ALLOWED';
  end if;

  if exists (select 1 from reservations
             where lower(email) = lower(p_email) and status = 'active') then
    raise exception 'ALREADY_BOOKED';
  end if;

  select capacity into v_cap from slots where id = p_slot_id for update; -- trava o horário
  if v_cap is null then raise exception 'SLOT_NOT_FOUND'; end if;

  select count(*) into v_used from reservations
    where slot_id = p_slot_id and status = 'active';
  if v_used >= v_cap then raise exception 'SLOT_FULL'; end if;

  insert into reservations (slot_id, email, name, phone, birth, pregnant,
                            surgery, surgery_detail, medium, intensity)
  values (p_slot_id, trim(p_email), p_name, p_phone, p_birth, p_pregnant,
          p_surgery, p_surgery_detail, p_medium, p_intensity)
  returning * into v_row;

  return v_row;
end;
$$;

-- Remarca (libera o horário antigo e ocupa o novo, atômico) via token do link.
create or replace function public.reschedule(p_token uuid, p_slot_id bigint)
returns public.reservations
language plpgsql security definer set search_path = public as $$
declare
  v_cap int; v_used int; v_row public.reservations;
begin
  select * into v_row from reservations where manage_token = p_token and status = 'active';
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_row.slot_id = p_slot_id then return v_row; end if;

  select capacity into v_cap from slots where id = p_slot_id for update;
  if v_cap is null then raise exception 'SLOT_NOT_FOUND'; end if;

  select count(*) into v_used from reservations
    where slot_id = p_slot_id and status = 'active';
  if v_used >= v_cap then raise exception 'SLOT_FULL'; end if;

  update reservations set slot_id = p_slot_id where id = v_row.id returning * into v_row;
  return v_row;
end;
$$;

-- Cancela via token do link.
create or replace function public.cancel(p_token uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update reservations set status = 'cancelled'
   where manage_token = p_token and status = 'active';
end;
$$;

-- Busca a reserva pelo token (para a página de gerenciamento do link).
create or replace function public.get_reservation(p_token uuid)
returns public.reservations
language sql security definer set search_path = public as $$
  select * from reservations where manage_token = p_token and status = 'active';
$$;

-- Permissões de execução (o app público usa o papel anônimo).
grant execute on function public.check_access(text)                        to anon, authenticated;
grant execute on function public.list_availability()                       to anon, authenticated;
grant execute on function public.reserve(text,text,text,date,text,text,text,text,text,bigint) to anon, authenticated;
grant execute on function public.reschedule(uuid,bigint)                   to anon, authenticated;
grant execute on function public.cancel(uuid)                              to anon, authenticated;
grant execute on function public.get_reservation(uuid)                     to anon, authenticated;

-- ----------------------------------------------------------------------
-- HORÁRIOS — Opção 1 (145 atendimentos)
-- ----------------------------------------------------------------------
insert into public.slots (slot_key, day_id, date_label, weekday, starts, ends, capacity, position) values
  ('d13-0830','d13','13 ago','qui','08:30','09:05',9,1),
  ('d13-0910','d13','13 ago','qui','09:10','09:45',9,2),
  ('d13-0950','d13','13 ago','qui','09:50','10:25',9,3),
  ('d13-1530','d13','13 ago','qui','15:30','16:05',9,4),
  ('d13-1610','d13','13 ago','qui','16:10','16:45',9,5),
  ('d13-1650','d13','13 ago','qui','16:50','17:25',9,6),
  ('d13-1730','d13','13 ago','qui','17:30','18:05',9,7),
  ('d14-0830','d14','14 ago','sex','08:30','09:05',9,8),
  ('d14-0910','d14','14 ago','sex','09:10','09:45',9,9),
  ('d14-0950','d14','14 ago','sex','09:50','10:25',9,10),
  ('d14-1400','d14','14 ago','sex','14:00','14:35',9,11),
  ('d14-1440','d14','14 ago','sex','14:40','15:15',9,12),
  ('d14-1520','d14','14 ago','sex','15:20','15:55',9,13),
  ('d15-0830','d15','15 ago','sáb','08:30','09:05',9,14),
  ('d15-0910','d15','15 ago','sáb','09:10','09:45',9,15),
  ('d15-0950','d15','15 ago','sáb','09:50','10:25',9,16),
  ('d15-1030','d15','15 ago','sáb','10:30','11:05',1,17)
on conflict (slot_key) do nothing;

-- ----------------------------------------------------------------------
-- EXEMPLO de como carregar autorizados/admins (troque pelos reais):
--   insert into public.allowlist (email) values ('fulano@empresa.com.br')
--     on conflict do nothing;
--   insert into public.admins (email) values ('voce@empresa.com.br')
--     on conflict do nothing;
-- ----------------------------------------------------------------------
