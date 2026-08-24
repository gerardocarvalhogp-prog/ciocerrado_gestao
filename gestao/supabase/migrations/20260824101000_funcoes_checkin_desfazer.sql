-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- funcoes-checkin.sql  ·  check-in no resort
--
-- Roda DEPOIS de schema.sql, schema-extra.sql e funcoes-patro.sql.
-- Chamado por checkin.html (perfil 'staff' basta - e a operacao do dia).
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 0. HELPER
-- =====================================================================

-- Todo mundo que a recepcao espera, numa lista so.
--
-- Sao duas origens: quem tem quarto (ocupantes) e quem foi cadastrado na
-- hora pela propria recepcao (checkins sem ocupante). A chave leva o
-- prefixo da origem porque os dois ids vem de tabelas diferentes e
-- poderiam colidir.
create or replace view v_checkin_esperados as
select
  'o:' || o.id::text        as pessoa_key,
  r.evento_id,
  o.id                      as ocupante_id,
  o.nome,
  coalesce(pt.empresa, g.empresa) as empresa,
  q.numero                  as quarto,
  case
    when o.data_nascimento is not null
     and age(o.data_nascimento) < interval '21 years' then 'S/CRACHA'
    else coalesce(o.categoria_cracha,
                  case when r.patrocinador_id is not null then 'PATROCINADOR'
                       when o.tipo = 'titular' then 'PROTAGONISTA'
                       else 'ACOMPANHANTE' end)
  end                       as categoria,
  r.patrocinador_id
from ocupantes o
join reservas r on r.id = o.reserva_id and r.status <> 'cancelado'
left join quartos q        on q.id = r.quarto_id
left join patrocinadores pt on pt.id = r.patrocinador_id
left join participantes pa on pa.id = r.participante_id
left join gestores g       on g.id = pa.gestor_id;

-- =====================================================================
-- 1. LISTAGEM E PLACAR
-- =====================================================================


-- =====================================================================
-- 2. REGISTRO
-- =====================================================================


-- Desfaz sem apagar. O registro fica para auditoria com quem desfez.
create or replace function checkin_desfazer(p_checkin_id uuid)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare v_n int;
begin
  if not is_staff() then raise exception 'Acesso restrito a equipe.'; end if;

  update checkins
     set desfeito_em = now(), desfeito_por = auth.jwt() ->> 'email'
   where id = p_checkin_id and desfeito_em is null;

  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'Check-in nao encontrado ou ja desfeito.'; end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- =====================================================================
-- 3. PERMISSOES
-- =====================================================================
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'gestao' and p.proname like 'checkin%'
  loop
    execute format('revoke execute on function %s from anon', f.sig);
  end loop;
end $$;
