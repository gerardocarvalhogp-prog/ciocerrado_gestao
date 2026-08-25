-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- A janela de escolha passa a ser relativa, e perder o prazo tira a
-- empresa da escolha.
--
-- DUAS MUDANCAS PEDIDAS PELO ORGANIZADOR
--
-- 1. "48h depois que a anterior encerrar", em vez de uma data fixa por
--    cota. O relogio de cada cota comeca quando a cota anterior fecha —
--    seja porque terminou de escolher, seja porque estourou a janela
--    dela. Assim a fila anda no ritmo do evento, e nao de datas
--    escolhidas no chute meses antes.
--
-- 2. Prazo vencido agora TIRA da escolha. Antes custava a fila e as
--    reservas, mas a empresa atrasada ainda podia pegar quem estivesse
--    livre. Nao mais: vencida a janela, ela esta fora daquela sessao.
--
-- ONDE FICAM OS CONTROLES
--
--   eventos.escolha_abre_em   quando a PRIMEIRA cota comeca a contar
--   cotas.janela_horas        quantas horas aquela cota tem
--   cotas.prazo_indicacao     teto absoluto opcional (o que veio antes)
--
-- A cota fecha no que vier primeiro entre os tres: terminar de
-- escolher, estourar as horas, ou passar da data-teto.
--
-- POR QUE A ANCORA E EXPLICITA
--
-- Seria mais barato comecar a contar quando as mesas sao criadas
-- (`sessoes.created_at`). Mas ai o organizador gera as sessoes tres
-- semanas antes, ninguem e avisado, e a janela da Esmeralda queima
-- sozinha. `escolha_abre_em` nulo = nada expira, que e o estado de
-- hoje: o relogio so comeca quando alguem diz que comecou.
--
-- CADEIA, NAO DATA
--
-- `_janelas_da_fila` percorre as cotas em ordem de prioridade e vai
-- somando: o fim de uma e o inicio da proxima. Por isso e um CTE
-- recursivo e nao uma coluna — o fim da Esmeralda so se sabe quando ela
-- fecha, e a Diamante depende disso.
--
-- Cota sem sessao daquele tipo nao segura a fila: fecha no mesmo
-- instante em que abre.
--
-- POR QUE HA DROP
--
-- Quatro funcoes mudam assinatura ou retorno. Sem o drop, o Postgres
-- criaria sobrecarga e as chamadas antigas cairiam na versao velha, sem
-- erro nenhum na tela.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. OS CONTROLES
-- ---------------------------------------------------------------------
alter table eventos add column if not exists escolha_abre_em timestamptz;
alter table cotas   add column if not exists janela_horas int;

comment on column eventos.escolha_abre_em is
  'Quando a primeira cota comeca a contar a janela de escolha. Nulo = nada expira.';
comment on column cotas.janela_horas is
  'Horas que esta cota tem para escolher, contadas do fim da cota anterior. Nulo = sem limite de tempo.';

alter table cotas drop constraint if exists cotas_janela_horas_check;
alter table cotas add constraint cotas_janela_horas_check
  check (janela_horas is null or janela_horas > 0);

-- ---------------------------------------------------------------------
-- 2. O FIM DE UMA JANELA
--
-- Tres coisas fecham uma cota, e vale a primeira que acontecer. `least`
-- ignora nulo, entao controle nao preenchido simplesmente nao entra na
-- conta.
-- ---------------------------------------------------------------------
create or replace function _fim_da_janela(
  p_inicio timestamptz,
  p_horas int,
  p_prazo date,
  p_fechou timestamptz,
  p_sem_sessao boolean
) returns timestamptz language sql immutable as $$
  select case
    -- cota que nao tem mesa deste tipo nao tem o que esperar
    when p_sem_sessao then p_inicio
    else least(
      case when p_inicio is not null and p_horas is not null
           then p_inicio + make_interval(hours => p_horas) end,
      -- o teto e o FIM do dia informado, nao o comeco dele
      case when p_prazo is not null then (p_prazo + 1)::timestamptz end,
      p_fechou)
  end;
$$;

-- A fila inteira, cota a cota: o fim de uma e o inicio da seguinte.
create or replace function _janelas_da_fila(p_evento uuid, p_tipo text)
returns table (cota_id uuid, ordem int, inicio timestamptz, fim timestamptz)
language sql stable security definer
set search_path = gestao, public as $$
  with recursive base as (
    select c.id,
           c.ordem_prioridade,
           row_number() over (order by c.ordem_prioridade, c.nome) as n,
           c.janela_horas,
           c.prazo_indicacao,
           (select count(s.id) = 0
              from patrocinadores p
              left join sessoes s on s.patrocinador_id = p.id
                                 and s.evento_id = p_evento
                                 and s.tipo = p_tipo
             where p.cota_id = c.id and p.status = 'ativo') as sem_sessao,
           -- so ha "fechou" quando TODAS as sessoes da cota fecharam;
           -- enquanto uma estiver escolhendo, a cota nao fechou
           (select case
                     when count(*) filter (where s.escolha_encerrada_em is null
                                             and s.passou_em is null) > 0
                       then null
                     else max(coalesce(s.escolha_encerrada_em, s.passou_em))
                   end
              from patrocinadores p
              join sessoes s on s.patrocinador_id = p.id
                            and s.evento_id = p_evento
                            and s.tipo = p_tipo
             where p.cota_id = c.id and p.status = 'ativo') as fechou_em
    from cotas c
    where c.evento_id = p_evento
  ),
  cadeia as (
    select b.id, b.ordem_prioridade::int as ordem, b.n,
           e.escolha_abre_em as inicio,
           _fim_da_janela(e.escolha_abre_em, b.janela_horas,
                          b.prazo_indicacao, b.fechou_em, b.sem_sessao) as fim
    from base b
    cross join (select escolha_abre_em from eventos where id = p_evento) e
    where b.n = 1
    union all
    select b.id, b.ordem_prioridade::int, b.n,
           c.fim,
           _fim_da_janela(c.fim, b.janela_horas,
                          b.prazo_indicacao, b.fechou_em, b.sem_sessao)
    from cadeia c
    join base b on b.n = c.n + 1
  )
  select id, ordem, inicio, fim from cadeia;
$$;

-- ---------------------------------------------------------------------
-- 3. "EM ABERTO" PASSA A OLHAR A JANELA
--
-- A cota que ainda nem comecou tambem conta como em aberto: ela segura
-- a fila de quem vem depois. Como o inicio de uma e o fim da anterior,
-- isso sai de graca — basta comparar com o FIM.
-- ---------------------------------------------------------------------
create or replace function _escolha_em_aberto(p_sessao_id uuid)
returns boolean language sql stable security definer
set search_path = gestao, public as $$
  select s.passou_em is null
     and s.escolha_encerrada_em is null
     and (select count(*) from sessao_convidados sc
           where sc.sessao_id = s.id and sc.status = 'confirmado') < s.vagas
     and (j.fim is null or now() < j.fim)
  from sessoes s
  join patrocinadores p on p.id = s.patrocinador_id
  left join lateral _janelas_da_fila(s.evento_id, s.tipo) j
         on j.cota_id = p.cota_id
  where s.id = p_sessao_id;
$$;

-- ---------------------------------------------------------------------
-- 4. A VEZ
-- ---------------------------------------------------------------------
create or replace function patro_minha_vez(p_sessao_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare
  v_patro uuid; v_evento uuid; v_tipo text; v_vagas int;
  v_pos bigint; v_na_frente int; v_escolhidos int;
  v_prazo date; v_inicio timestamptz; v_fim timestamptz;
begin
  select s.patrocinador_id, s.evento_id, s.tipo, s.vagas
    into v_patro, v_evento, v_tipo, v_vagas
  from sessoes s where s.id = p_sessao_id;

  perform _exige_patrocinador(v_patro);

  select o.posicao into v_pos
  from v_ordem_escolha o where o.patrocinador_id = v_patro;

  select c.prazo_indicacao into v_prazo
  from patrocinadores p join cotas c on c.id = p.cota_id
  where p.id = v_patro;

  select j.inicio, j.fim into v_inicio, v_fim
  from patrocinadores p
  join lateral _janelas_da_fila(v_evento, v_tipo) j on j.cota_id = p.cota_id
  where p.id = v_patro;

  select count(*) into v_na_frente
  from sessoes s2
  join v_ordem_escolha o2 on o2.patrocinador_id = s2.patrocinador_id
  where s2.evento_id = v_evento
    and s2.tipo = v_tipo
    and o2.posicao < coalesce(v_pos, 999999)
    and _escolha_em_aberto(s2.id);

  select count(*) into v_escolhidos from sessao_convidados
   where sessao_id = p_sessao_id and status = 'confirmado';

  return jsonb_build_object(
    -- nao basta nao ter ninguem na frente: a propria janela precisa
    -- estar de pe. Perder o prazo agora tira da escolha.
    'minha_vez',     v_na_frente = 0 and coalesce(_escolha_em_aberto(p_sessao_id), false),
    'posicao',       coalesce(v_pos, 0),
    'na_frente',     v_na_frente,
    'vagas',         v_vagas,
    'escolhidos',    v_escolhidos,
    'prazo',         v_prazo,
    'janela_inicio', v_inicio,
    'janela_fim',    v_fim,
    'prazo_vencido', v_fim is not null and now() >= v_fim
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. A ESCOLHA
-- ---------------------------------------------------------------------
create or replace function patro_escolher_convidados(
  p_sessao_id uuid,
  p_participantes uuid[]
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_patro uuid; v_vagas int; v_tipo text; v_evento uuid;
  v_atual int; v_vez jsonb; v_inseridos int := 0; v_p uuid;
  v_dono uuid; v_empresa text;
begin
  select s.patrocinador_id, s.vagas, s.tipo, s.evento_id
    into v_patro, v_vagas, v_tipo, v_evento
  from sessoes s where s.id = p_sessao_id
  for update;                       -- trava a sessao durante a escolha

  perform _exige_patrocinador(v_patro);

  v_vez := patro_minha_vez(p_sessao_id);

  -- janela vencida vem antes da vez: com 0 na frente, a mensagem de
  -- "nao e a sua vez" nao explicaria nada
  if (v_vez ->> 'prazo_vencido')::boolean then
    raise exception 'O prazo da sua cota terminou em %. A escolha passou para as proximas cotas.',
      to_char((v_vez ->> 'janela_fim')::timestamptz, 'DD/MM/YYYY HH24:MI')
      using errcode = '55000';
  end if;

  if not (v_vez ->> 'minha_vez')::boolean then
    raise exception 'Ainda nao e a sua vez de escolher (% na frente)',
      v_vez ->> 'na_frente' using errcode = '55000';
  end if;

  select count(*) into v_atual from sessao_convidados
   where sessao_id = p_sessao_id and status = 'confirmado';

  if v_atual + array_length(p_participantes,1) > v_vagas then
    raise exception 'Cota de % vaga(s); voce ja tem % e tentou somar %',
      v_vagas, v_atual, array_length(p_participantes,1)
      using errcode = '22023';
  end if;

  foreach v_p in array p_participantes loop
    -- ninguem pode estar em duas sessoes do mesmo tipo
    if exists (
      select 1 from sessao_convidados sc
      join sessoes s3 on s3.id = sc.sessao_id
      where sc.participante_id = v_p and sc.status = 'confirmado'
        and s3.evento_id = v_evento and s3.tipo = v_tipo
    ) then
      raise exception 'Convidado ja esta em outra sessao deste tipo'
        using errcode = '23505';
    end if;

    v_dono := _reserva_da_indicacao(v_p, v_tipo);
    if v_dono is not null and v_dono <> v_patro then
      select empresa into v_empresa from patrocinadores where id = v_dono;
      raise exception 'Convidado indicado pela %, que ainda esta no prazo', v_empresa
        using errcode = '55000';
    end if;

    insert into sessao_convidados (sessao_id, participante_id, origem)
    values (p_sessao_id, v_p, 'patrocinador');
    v_inseridos := v_inseridos + 1;
  end loop;

  if v_atual + v_inseridos >= v_vagas then
    update sessoes set escolha_encerrada_em = now() where id = p_sessao_id;
  end if;

  return jsonb_build_object('ok', true, 'inseridos', v_inseridos,
                            'total', v_atual + v_inseridos, 'vagas', v_vagas);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. OS CONTROLES NA TELA DA ORGANIZACAO
-- ---------------------------------------------------------------------
drop function if exists admin_listar_cotas(text);

create function admin_listar_cotas(p_evento_slug text)
returns table (id uuid, nome text, ordem_prioridade int,
               quartos jsonb, total_quartos bigint,
               vagas_mesa_redonda int, tem_reuniao_exclusiva boolean,
               tem_jantar boolean, patrocinadores bigint,
               lista_patrocinadores jsonb, prazo_indicacao date,
               janela_horas int)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select c.id, c.nome, c.ordem_prioridade,
           coalesce((select jsonb_object_agg(cq.tipo, cq.quantidade)
                     from cota_quartos cq where cq.cota_id = c.id
                       and cq.quantidade > 0), '{}'::jsonb),
           coalesce((select sum(cq.quantidade) from cota_quartos cq
                     where cq.cota_id = c.id), 0),
           c.vagas_mesa_redonda, c.tem_reuniao_exclusiva, c.tem_jantar,
           (select count(*) from patrocinadores p where p.cota_id = c.id),
           coalesce((select jsonb_agg(jsonb_build_object(
                       'id', p.id, 'empresa', p.empresa) order by p.empresa)
                     from patrocinadores p
                     where p.cota_id = c.id and p.status = 'ativo'), '[]'::jsonb),
           c.prazo_indicacao, c.janela_horas
    from cotas c
    join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade;
end;
$$;

-- p_quartos vem como {"duplo":2,"single":2}
drop function if exists admin_salvar_cota(text, text, int, jsonb, int, boolean, boolean, date);

create function admin_salvar_cota(
  p_evento_slug text,
  p_nome text,
  p_ordem int,
  p_quartos jsonb default '{}'::jsonb,
  p_vagas_mesa int default 0,
  p_reuniao boolean default false,
  p_jantar boolean default false,
  p_prazo_indicacao date default null,
  p_janela_horas int default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_unica boolean; v_conflito text;
  v_cota uuid; v_par record; v_ordem int; v_total int := 0;
begin
  perform _exige_admin();

  select id, cota_unica into v_evento, v_unica
  from eventos where slug = p_evento_slug;

  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome da cota' using errcode='22023';
  end if;
  if p_janela_horas is not null and p_janela_horas <= 0 then
    raise exception 'A janela em horas comeca em 1' using errcode='22023';
  end if;

  -- Em evento de cota unica nao ha fila, entao a ordem nao e pedida na
  -- tela; forcamos 1 para nao deixar nulo e quebrar a view de ordem.
  v_ordem := case when v_unica then 1 else p_ordem end;

  if v_ordem is null or v_ordem < 1 then
    raise exception 'A ordem de prioridade comeca em 1' using errcode='22023';
  end if;

  if not v_unica then
    select c.nome into v_conflito from cotas c
     where c.evento_id = v_evento and c.ordem_prioridade = v_ordem
       and lower(c.nome) <> lower(trim(p_nome));
    if v_conflito is not null then
      raise exception 'A posicao % ja e da cota "%"', v_ordem, v_conflito
        using errcode='23505';
    end if;
  end if;

  insert into cotas (evento_id, nome, ordem_prioridade, vagas_mesa_redonda,
                     tem_reuniao_exclusiva, tem_jantar,
                     quartos_incluidos, tipo_quarto_padrao, prazo_indicacao,
                     janela_horas)
  values (v_evento, trim(p_nome), v_ordem, coalesce(p_vagas_mesa,0),
          p_reuniao, p_jantar, 0, 'duplo', p_prazo_indicacao, p_janela_horas)
  on conflict (evento_id, nome) do update set
    ordem_prioridade = excluded.ordem_prioridade,
    vagas_mesa_redonda = excluded.vagas_mesa_redonda,
    tem_reuniao_exclusiva = excluded.tem_reuniao_exclusiva,
    tem_jantar = excluded.tem_jantar,
    prazo_indicacao = excluded.prazo_indicacao,
    janela_horas = excluded.janela_horas
  returning id into v_cota;

  -- composicao substitui a anterior inteira: a tela edita o conjunto
  delete from cota_quartos where cota_id = v_cota;

  for v_par in
    select key as tipo, (value #>> '{}')::int as qtd
    from jsonb_each(coalesce(p_quartos, '{}'::jsonb))
  loop
    if v_par.tipo not in ('single','duplo','triplo') then
      raise exception 'Tipo de quarto invalido: %', v_par.tipo using errcode='22023';
    end if;
    if coalesce(v_par.qtd,0) > 0 then
      insert into cota_quartos (cota_id, tipo, quantidade)
      values (v_cota, v_par.tipo, v_par.qtd);
      v_total := v_total + v_par.qtd;
    end if;
  end loop;

  -- mantem as colunas antigas coerentes para quem ainda as le
  update cotas set quartos_incluidos = v_total where id = v_cota;

  return jsonb_build_object('ok', true, 'id', v_cota, 'total_quartos', v_total);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. A ANCORA, NO EVENTO
-- ---------------------------------------------------------------------
drop function if exists admin_listar_eventos();

create function admin_listar_eventos()
returns table (id uuid, slug text, nome text, local text,
               data_inicio date, data_fim date, status text,
               cota_unica boolean, prazo_contrato date, prazo_rooming date,
               prazo_cancelamento date, participantes bigint,
               escolha_abre_em timestamptz)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select e.id, e.slug, e.nome, e.local, e.data_inicio, e.data_fim,
           e.status, e.cota_unica,
           e.prazo_contrato, e.prazo_rooming, e.prazo_cancelamento,
           (select count(*) from participantes p where p.evento_id = e.id),
           e.escolha_abre_em
    from eventos e
    order by e.data_inicio desc nulls last;
end;
$$;

drop function if exists admin_salvar_evento(text, text, text, date, date, text,
                                            date, date, date, text, boolean);

create function admin_salvar_evento(
  p_slug text,
  p_nome text,
  p_local text default null,
  p_data_inicio date default null,
  p_data_fim date default null,
  p_status text default 'rascunho',
  p_prazo_contrato date default null,
  p_prazo_rooming date default null,
  p_prazo_cancelamento date default null,
  p_sympla_event_id text default null,
  p_cota_unica boolean default false,
  p_escolha_abre_em timestamptz default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_slug text; v_id uuid; v_cotas int;
begin
  perform _exige_admin();

  v_slug := trim(both '-' from regexp_replace(
    lower(unaccent('unaccent', coalesce(trim(p_slug),''))), '[^a-z0-9]+','-','g'));

  if v_slug = '' then
    raise exception 'Informe o identificador do evento' using errcode='22023';
  end if;
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome do evento' using errcode='22023';
  end if;
  if p_status not in ('rascunho','aberto','encerrado') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;
  if p_data_inicio is not null and p_data_fim is not null
     and p_data_fim < p_data_inicio then
    raise exception 'A data final e anterior a inicial' using errcode='22023';
  end if;

  -- Virar cota unica com varias cotas ja criadas deixaria a fila de
  -- escolha sem sentido, entao o caminho e limpar as cotas antes.
  if p_cota_unica then
    select count(*) into v_cotas from cotas c
    join eventos e on e.id = c.evento_id
    where e.slug = v_slug;
    if v_cotas > 1 then
      raise exception
        'Este evento tem % cotas. Remova-as antes de marcar como cota unica.', v_cotas
        using errcode='22023';
    end if;
  end if;

  insert into eventos (slug, nome, local, data_inicio, data_fim, status,
                       prazo_contrato, prazo_rooming, prazo_cancelamento,
                       sympla_event_id, cota_unica, escolha_abre_em)
  values (v_slug, trim(p_nome), p_local, p_data_inicio, p_data_fim, p_status,
          p_prazo_contrato, p_prazo_rooming, p_prazo_cancelamento,
          p_sympla_event_id, coalesce(p_cota_unica,false), p_escolha_abre_em)
  on conflict (slug) do update set
    nome = excluded.nome, local = excluded.local,
    data_inicio = excluded.data_inicio, data_fim = excluded.data_fim,
    status = excluded.status,
    prazo_contrato = excluded.prazo_contrato,
    prazo_rooming = excluded.prazo_rooming,
    prazo_cancelamento = excluded.prazo_cancelamento,
    sympla_event_id = coalesce(excluded.sympla_event_id, eventos.sympla_event_id),
    cota_unica = excluded.cota_unica,
    escolha_abre_em = excluded.escolha_abre_em
  returning id into v_id;

  -- Evento de cota unica ja nasce com a cota pronta: sem ela o
  -- patrocinador nao consegue ser cadastrado.
  if coalesce(p_cota_unica,false) then
    insert into cotas (evento_id, nome, ordem_prioridade, quartos_incluidos,
                       tipo_quarto_padrao, vagas_mesa_redonda,
                       tem_reuniao_exclusiva, tem_jantar)
    values (v_id, 'Única', 1, 0, 'duplo', 0, false, true)
    on conflict (evento_id, nome) do nothing;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'slug', v_slug,
                            'cota_unica', coalesce(p_cota_unica,false));
end;
$$;

-- ---------------------------------------------------------------------
-- 8. PERMISSAO
-- ---------------------------------------------------------------------
revoke execute on function admin_listar_cotas(text) from public, anon;
revoke execute on function admin_listar_eventos() from public, anon;
revoke execute on function _fim_da_janela(timestamptz, int, date, timestamptz, boolean) from public, anon;
revoke execute on function _janelas_da_fila(uuid, text) from public, anon;
revoke execute on function admin_salvar_cota(text, text, int, jsonb, int, boolean, boolean, date, int) from public, anon;
revoke execute on function admin_salvar_evento(text, text, text, date, date, text, date, date, date, text, boolean, timestamptz) from public, anon;

grant execute on function admin_listar_cotas(text) to authenticated, service_role;
grant execute on function admin_listar_eventos() to authenticated, service_role;
grant execute on function _fim_da_janela(timestamptz, int, date, timestamptz, boolean) to authenticated, service_role;
grant execute on function _janelas_da_fila(uuid, text) to authenticated, service_role;
grant execute on function admin_salvar_cota(text, text, int, jsonb, int, boolean, boolean, date, int) to authenticated, service_role;
grant execute on function admin_salvar_evento(text, text, text, date, date, text, date, date, date, text, boolean, timestamptz) to authenticated, service_role;
