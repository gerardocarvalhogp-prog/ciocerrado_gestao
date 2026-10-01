-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- admin_adicionar_convidado_sessao (lado do STAFF) nunca conferiu se o
-- CIO ja estava confirmado em OUTRA sessao do mesmo tipo — so'
-- patro_escolher_convidados (lado do patrocinador, autoatendimento)
-- tinha essa trava, desde 20260902120000. Pedido do organizador em
-- 01/10/2026 ("confirmar se nao estamos deixando um CIO em mais de uma
-- mesa"): confirmado que SIM, dava pra duplicar pela tela de staff —
-- corrigido com a MESMA regra e a MESMA mensagem de erro que
-- patro_escolher_convidados ja usa, pra nao ter duas definicoes
-- divergentes do que conta como "duplicado".
--
-- Escopo igual ao existente: MESMO tipo (mesa_redonda, reuniao_exclusiva
-- ou jantar) — um CIO pode estar numa mesa redonda E num jantar ao
-- mesmo tempo, sao coisas diferentes. So nao pode estar em DUAS mesas
-- redondas, por exemplo.
--
-- Autoconfere tambem se ja EXISTE duplicata nos dados de verdade
-- (RAISE NOTICE, nao bloqueia a migration — um achado desses e decisao
-- de quem organiza, de qual mesa tirar a pessoa, nao algo pra escolher
-- sozinho numa migration).
-- =====================================================================

set search_path = gestao, public;

create or replace function admin_adicionar_convidado_sessao(p_sessao_id uuid, p_participante_id uuid, p_aderencia numeric DEFAULT NULL::numeric)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_vagas int;
  v_ocupadas int;
  v_evento uuid;
  v_tipo text;
begin
  perform _exige_staff_da_sessao(p_sessao_id);

  select vagas, evento_id, tipo into v_vagas, v_evento, v_tipo
  from sessoes where id = p_sessao_id for update;
  if not found then
    raise exception 'Sessao nao encontrada' using errcode = 'P0002';
  end if;

  if exists (
    select 1 from sessao_convidados sc
    join sessoes s3 on s3.id = sc.sessao_id
    where sc.participante_id = p_participante_id and sc.status = 'confirmado'
      and s3.evento_id = v_evento and s3.tipo = v_tipo
      and sc.sessao_id <> p_sessao_id
  ) then
    raise exception 'Convidado ja esta em outra sessao deste tipo'
      using errcode = '23505';
  end if;

  -- nao conta a propria pessoa: reconfirmar quem ja esta (ou trazer de
  -- volta quem foi removido) nunca deveria esbarrar na propria vaga
  select count(*) into v_ocupadas from sessao_convidados
   where sessao_id = p_sessao_id and status = 'confirmado'
     and participante_id <> p_participante_id;

  if v_ocupadas >= coalesce(v_vagas, 0) then
    raise exception 'Mesa sem vaga: % de % confirmado(s)', v_ocupadas, coalesce(v_vagas,0)
      using errcode = '55000';
  end if;

  insert into sessao_convidados (sessao_id, participante_id, origem, aderencia)
  values (p_sessao_id, p_participante_id, 'admin', p_aderencia)
  on conflict (sessao_id, participante_id) do update set
    status = 'confirmado',
    origem = 'admin',
    aderencia = coalesce(excluded.aderencia, sessao_convidados.aderencia);

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function admin_adicionar_convidado_sessao(uuid, uuid, numeric) from public, anon;
grant execute on function admin_adicionar_convidado_sessao(uuid, uuid, numeric) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- MATRIZ PATROCINADOR / MESA / CIO ESCOLHIDO — mesmo pedido, pra ver
-- tudo de uma vez em vez de abrir sessao por sessao. Uma linha por
-- convidado confirmado; mesa sem ninguem ainda aparece com cio_nome
-- nulo (left join), pra nao esconder vaga vazia do relatorio.
-- ---------------------------------------------------------------------
create or replace function admin_matriz_sessoes(p_evento_slug text)
returns table (
  patrocinador text, cota text, tipo text, data date, horario time,
  vagas integer, cio_nome text, cio_empresa text
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select p.empresa, c.nome, s.tipo, s.data, s.horario, s.vagas,
           g.nome, g.empresa
    from sessoes s
    join patrocinadores p on p.id = s.patrocinador_id
    join eventos e on e.id = s.evento_id and e.slug = p_evento_slug
    left join cotas c on c.id = p.cota_id
    left join sessao_convidados sc on sc.sessao_id = s.id and sc.status = 'confirmado'
    left join participantes pa on pa.id = sc.participante_id
    left join gestores g on g.id = pa.gestor_id
    order by c.ordem_prioridade nulls last, p.empresa, s.tipo, s.data, s.horario, g.nome;
end;
$$;

revoke execute on function admin_matriz_sessoes(text) from public, anon;
grant execute on function admin_matriz_sessoes(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- BUSCA PRA "ADICIONAR OUTRO CONVIDADO" — so' em quem ja esta inscrito
-- e aprovado (passou pelo Sympla), nunca cria gente nova. admin_convidado
-- _avulso (20260831180000) fazia isso — recebia nome/empresa digitados
-- e, sem achar gestor com aquele e-mail, CRIAVA um gestor+participante
-- novo na hora, auto-aprovado, sem checar inscricao nenhuma. admin.html
-- (proximo commit) para de chamar essa funcao pro formulario "Adicionar
-- outro convidado" — ela fica no banco (ninguem mais a chama) por
-- cautela, em vez de apagar sem certeza absoluta de que nada mais
-- depende dela. Pedido do organizador em 01/10/2026: "só trazer CIOs
-- confirmados... inscrição no Sympla feita".
--
-- Mesma exclusao de quem ja esta em outra sessao do mesmo tipo
-- (admin_adicionar_convidado_sessao, acima, recusaria do mesmo jeito —
-- aqui e so pra nao nem OFERECER quem a tela ia recusar depois).
-- ---------------------------------------------------------------------
create or replace function admin_buscar_participantes_sessao(p_sessao_id uuid, p_termo text default null)
returns table (participante_id uuid, nome text, empresa text, cargo text)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_tipo text;
begin
  perform _exige_staff_da_sessao(p_sessao_id);

  select evento_id, tipo into v_evento, v_tipo from sessoes where id = p_sessao_id;
  if v_evento is null then
    raise exception 'Sessao nao encontrada' using errcode = 'P0002';
  end if;

  return query
    select pa.id, g.nome, g.empresa, g.cargo
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    where pa.evento_id = v_evento
      and pa.status = 'aprovado'
      and (
        coalesce(trim(p_termo),'') = ''
        or unaccent('unaccent', g.nome)    ilike '%' || unaccent('unaccent', trim(p_termo)) || '%'
        or unaccent('unaccent', g.empresa) ilike '%' || unaccent('unaccent', trim(p_termo)) || '%'
      )
      and not exists (
        select 1 from sessao_convidados sc
        join sessoes s3 on s3.id = sc.sessao_id
        where sc.participante_id = pa.id and sc.status = 'confirmado'
          and s3.evento_id = v_evento and s3.tipo = v_tipo
      )
    order by g.nome
    limit 30;
end;
$$;

revoke execute on function admin_buscar_participantes_sessao(uuid, text) from public, anon;
grant execute on function admin_buscar_participantes_sessao(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- autoconfere: reporta (sem bloquear) qualquer CIO ja duplicado em mais
-- de uma sessao do mesmo tipo, nos dados de hoje
-- ---------------------------------------------------------------------
do $$
declare
  v_registro record;
  v_qtd int := 0;
begin
  for v_registro in
    select g.nome, s.tipo, e.slug as evento,
           string_agg(distinct p.empresa, ', ') as mesas_de
    from sessao_convidados sc
    join sessoes s on s.id = sc.sessao_id
    join eventos e on e.id = s.evento_id
    join participantes pa on pa.id = sc.participante_id
    join gestores g on g.id = pa.gestor_id
    join patrocinadores p on p.id = s.patrocinador_id
    where sc.status = 'confirmado'
    group by g.nome, s.tipo, e.slug, sc.participante_id, s.evento_id
    having count(distinct sc.sessao_id) > 1
  loop
    v_qtd := v_qtd + 1;
    raise warning 'DUPLICADO: % esta em mais de uma sessao "%" no evento % (mesas: %)',
      v_registro.nome, v_registro.tipo, v_registro.evento, v_registro.mesas_de;
  end loop;

  if v_qtd = 0 then
    raise notice 'Conferido: nenhum CIO duplicado em mais de uma sessao do mesmo tipo.';
  else
    raise notice '% CIO(s) duplicado(s) encontrado(s) nos dados atuais — ver os WARNING acima, resolver na mao (aba Sessoes, "Remover" na mesa errada).', v_qtd;
  end if;
end $$;
