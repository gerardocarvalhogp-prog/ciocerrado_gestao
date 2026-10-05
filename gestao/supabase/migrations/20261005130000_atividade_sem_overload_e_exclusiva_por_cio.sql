-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Atividade: some o overload orfao de admin_salvar_atividade, e a lista
-- exclusiva passa a reconhecer o CIO que ja preencheu o rooming.
--
-- Achados dos testes 19 e 23 (05/10/2026), decisao do organizador:
-- corrigir.
--
-- 1. 20260902220000 criou admin_salvar_atividade com 8 parametros
--    (p_tipo_presenca) via CREATE OR REPLACE, sem dropar a de 7 — que
--    ficou viva ao lado (mesmo problema que 20260909170000 consertou em
--    admin_salvar_cota). admin.html manda os 8 e funciona; chamada sem
--    p_tipo_presenca dava "function ... is not unique". Sai a de 7.
--
-- 2. A lista fechada (atividade_convidados) guarda participante_id, e a
--    porta casava so pela chave 'participante:<id>'. Mas v_esperados so
--    gera essa chave pra quem NAO tem reserva — quem preencheu o rooming
--    vira 'ocupante:<id>' (o titular da reserva). Resultado: o CIO na
--    lista sumia da lista da porta e o check-in pelo cracha era recusado.
--    No evento de verdade todo CIO tem rooming — a exclusiva ficava
--    inutilizavel. Agora as duas chaves resolvem pro participante:
--    'participante:<id>' direto, 'ocupante:<id>' so quando e o TITULAR
--    da reserva principal do CIO (familiar e quem dorme no quarto extra
--    nao entram na lista do CIO).
-- =====================================================================

set search_path = gestao, public;

drop function if exists admin_salvar_atividade(uuid, text, text, date, time, time, text);

create or replace function _participante_da_pessoa_key(p_pessoa_key text)
returns uuid language sql stable security definer
set search_path = gestao, public as $$
  select case
    when p_pessoa_key like 'participante:%' then substring(p_pessoa_key from 14)::uuid
    when p_pessoa_key like 'ocupante:%' then (
      select r.participante_id
      from ocupantes o
      join reservas r on r.id = o.reserva_id
      where o.id = substring(p_pessoa_key from 10)::uuid
        and o.tipo = 'titular'
        and r.origem <> 'extra'
        and r.status <> 'cancelado')
  end;
$$;

comment on function _participante_da_pessoa_key(text) is
  'Resolve a chave do cracha (v_esperados) pro participante: participante:<id> direto, ocupante:<id> so se for o titular da reserva principal. Uso interno.';

revoke all on function _participante_da_pessoa_key(text) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION gestao.atividade_checkin_listar(p_atividade_id uuid, p_termo text DEFAULT NULL::text, p_so_pendentes boolean DEFAULT false, p_limite integer DEFAULT 300)
 RETURNS TABLE(pessoa_key text, nome text, empresa text, categoria text, checkin_id uuid, registrado_em timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v_evento uuid; v_tipo text; v_termo text;
begin
  perform _exige_staff_da_atividade(p_atividade_id);
  select evento_id, tipo_presenca into v_evento, v_tipo from atividades where id = p_atividade_id;
  if v_evento is null then
    raise exception 'Atividade nao encontrada' using errcode = 'P0002';
  end if;
  v_termo := nullif(trim(coalesce(p_termo,'')), '');

  return query
    select v.pessoa_key, v.nome, v.empresa, v.categoria, c.id, c.registrado_em
    from v_esperados v
    left join checkins c on c.pessoa_key = v.pessoa_key
                         and c.atividade_id = p_atividade_id
                         and c.desfeito_em is null
    where v.evento_id = v_evento
      and (v_tipo <> 'exclusiva'
           or exists(select 1 from atividade_convidados ac
                      where ac.atividade_id = p_atividade_id
                        and ac.participante_id = _participante_da_pessoa_key(v.pessoa_key)))
      and (v_termo is null
           or v.nome ilike '%'||v_termo||'%'
           or coalesce(v.empresa,'') ilike '%'||v_termo||'%')
      and (not p_so_pendentes or c.id is null)
    order by (c.id is not null), v.nome
    limit p_limite;
end;
$function$;

CREATE OR REPLACE FUNCTION gestao.atividade_checkin_registrar(p_atividade_id uuid, p_pessoa_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_evento uuid; v_tipo text; v_nome text; v_email text; v_patro uuid; v_ocupante uuid;
  v_ja timestamptz; v_id uuid;
begin
  perform _exige_staff_da_atividade(p_atividade_id);

  select evento_id, tipo_presenca into v_evento, v_tipo from atividades where id = p_atividade_id;
  if v_evento is null then
    raise exception 'Atividade nao encontrada' using errcode = 'P0002';
  end if;

  if v_tipo = 'exclusiva' and not exists(
    select 1 from atividade_convidados ac
     where ac.atividade_id = p_atividade_id
       and ac.participante_id = _participante_da_pessoa_key(p_pessoa_key)
  ) then
    raise exception 'Essa pessoa nao esta na lista fechada desta atividade' using errcode = '22023';
  end if;

  select v.nome, v.email, v.patrocinador_id
    into v_nome, v_email, v_patro
  from v_esperados v
  where v.pessoa_key = p_pessoa_key and v.evento_id = v_evento;

  if v_nome is null then
    raise exception 'Pessoa nao encontrada neste evento' using errcode = 'P0002';
  end if;

  if p_pessoa_key like 'ocupante:%' then
    v_ocupante := substring(p_pessoa_key from 10)::uuid;
  end if;

  select c.registrado_em into v_ja from checkins c
   where c.pessoa_key = p_pessoa_key and c.atividade_id = p_atividade_id
     and c.desfeito_em is null
   limit 1;

  if v_ja is not null then
    return jsonb_build_object('ok', true, 'ja_estava', true,
                              'nome', v_nome, 'registrado_em', v_ja);
  end if;

  insert into checkins (evento_id, patrocinador_id, ocupante_id, pessoa_key,
                        nome, email, atividade_id, registrado_por)
  values (v_evento, v_patro, v_ocupante, p_pessoa_key, v_nome, v_email,
          p_atividade_id, auth.jwt() ->> 'email')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'ja_estava', false, 'id', v_id, 'nome', v_nome);
end;
$function$;
