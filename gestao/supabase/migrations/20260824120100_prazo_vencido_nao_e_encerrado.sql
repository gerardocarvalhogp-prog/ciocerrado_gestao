-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- "Acabou o tempo" e "terminou de escolher" nao sao a mesma coisa.
--
-- O DEFEITO
--
-- `_janelas_da_fila` devolvia um `fim` so, que era o menor entre tres
-- coisas: as horas da janela, o prazo-teto e o momento em que a cota
-- terminou de escolher. Para andar a fila isso esta certo — a proxima
-- cota comeca quando a anterior sai, seja por tempo ou por ter acabado.
--
-- Mas `patro_minha_vez` derivava `prazo_vencido` desse mesmo `fim`. Ou
-- seja: quem PASSOU A VEZ recebia "O prazo da sua cota terminou em
-- 25/08 01:21. A escolha passou para as proximas cotas." Nao terminou
-- prazo nenhum; a empresa desistiu, por vontade propria, um segundo
-- antes. O teste 03 pegou isso.
--
-- Alem de confuso, e injusto na direcao errada: manda para o
-- patrocinador uma mensagem de falha por atraso quando ele nao atrasou.
--
-- A CORRECAO
--
-- A funcao passa a devolver DUAS datas:
--
--   limite  quando o TEMPO acaba (horas da janela ou prazo-teto)
--   fim     quando a cota sai da fila (limite ou terminou de escolher,
--           o que vier primeiro) — e o que define o inicio da proxima
--
-- `prazo_vencido` e a mensagem de erro passam a olhar so o `limite`. A
-- cadeia da fila continua olhando o `fim`.
--
-- O JSON de patro_minha_vez mantem a chave `janela_fim`, agora com o
-- limite: e a data que o patrocinador precisa ver — ate quando ELE
-- pode escolher. O front nao muda.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. O LIMITE DE TEMPO, SEPARADO
-- ---------------------------------------------------------------------
create or replace function _limite_da_janela(
  p_inicio timestamptz,
  p_horas int,
  p_prazo date,
  p_sem_sessao boolean
) returns timestamptz language sql immutable
set search_path = gestao, public as $$
  select case
    when p_sem_sessao then p_inicio
    else least(
      case when p_inicio is not null and p_horas is not null
           then p_inicio + make_interval(hours => p_horas) end,
      case when p_prazo is not null then (p_prazo + 1)::timestamptz end)
  end;
$$;

-- ---------------------------------------------------------------------
-- 2. A CADEIA, COM AS DUAS DATAS
--
-- DROP porque o retorno ganha coluna. As duas funcoes que dependem
-- desta sao recriadas logo abaixo, na mesma migration.
-- ---------------------------------------------------------------------
drop function if exists _janelas_da_fila(uuid, text);

create function _janelas_da_fila(p_evento uuid, p_tipo text)
returns table (cota_id uuid, ordem int, inicio timestamptz,
               limite timestamptz, fim timestamptz)
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
           -- so ha "fechou" quando TODAS as sessoes da cota fecharam
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
           _limite_da_janela(e.escolha_abre_em, b.janela_horas,
                             b.prazo_indicacao, b.sem_sessao) as limite,
           least(
             _limite_da_janela(e.escolha_abre_em, b.janela_horas,
                               b.prazo_indicacao, b.sem_sessao),
             case when b.sem_sessao then null else b.fechou_em end) as fim
    from base b
    cross join (select escolha_abre_em from eventos where id = p_evento) e
    where b.n = 1
    union all
    select b.id, b.ordem_prioridade::int, b.n,
           c.fim,
           _limite_da_janela(c.fim, b.janela_horas,
                             b.prazo_indicacao, b.sem_sessao),
           least(
             _limite_da_janela(c.fim, b.janela_horas,
                               b.prazo_indicacao, b.sem_sessao),
             case when b.sem_sessao then null else b.fechou_em end)
    from cadeia c
    join base b on b.n = c.n + 1
  )
  select id, ordem, inicio, limite, fim from cadeia;
$$;

-- ---------------------------------------------------------------------
-- 3. "EM ABERTO" OLHA O LIMITE
--
-- As outras razoes de fechamento (passou a vez, encerrou, encheu) ja
-- sao checadas direto na sessao, aqui em cima. O que falta e o tempo.
-- ---------------------------------------------------------------------
create or replace function _escolha_em_aberto(p_sessao_id uuid)
returns boolean language sql stable security definer
set search_path = gestao, public as $$
  select s.passou_em is null
     and s.escolha_encerrada_em is null
     and (select count(*) from sessao_convidados sc
           where sc.sessao_id = s.id and sc.status = 'confirmado') < s.vagas
     and (j.limite is null or now() < j.limite)
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
  v_prazo date; v_inicio timestamptz; v_limite timestamptz;
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

  select j.inicio, j.limite into v_inicio, v_limite
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
    'minha_vez',     v_na_frente = 0 and coalesce(_escolha_em_aberto(p_sessao_id), false),
    'posicao',       coalesce(v_pos, 0),
    'na_frente',     v_na_frente,
    'vagas',         v_vagas,
    'escolhidos',    v_escolhidos,
    'prazo',         v_prazo,
    'janela_inicio', v_inicio,
    -- a data que o patrocinador precisa ver e ate quando ELE escolhe,
    -- nao quando a cota saiu da fila
    'janela_fim',    v_limite,
    'prazo_vencido', v_limite is not null and now() >= v_limite
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. E A RECUSA DIZ O MOTIVO CERTO
--
-- Com `minha_vez` falso e ninguem na frente, a mensagem antiga era
-- "Ainda nao e a sua vez de escolher (0 na frente)" — verdadeira e
-- inutil. Sao tres motivos diferentes e cada um merece a sua frase.
-- ---------------------------------------------------------------------
create or replace function patro_escolher_convidados(
  p_sessao_id uuid,
  p_participantes uuid[]
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_patro uuid; v_vagas int; v_tipo text; v_evento uuid;
  v_atual int; v_vez jsonb; v_inseridos int := 0; v_p uuid;
  v_dono uuid; v_empresa text; v_passou timestamptz; v_encerrada timestamptz;
begin
  select s.patrocinador_id, s.vagas, s.tipo, s.evento_id,
         s.passou_em, s.escolha_encerrada_em
    into v_patro, v_vagas, v_tipo, v_evento, v_passou, v_encerrada
  from sessoes s where s.id = p_sessao_id
  for update;                       -- trava a sessao durante a escolha

  perform _exige_patrocinador(v_patro);

  v_vez := patro_minha_vez(p_sessao_id);

  if v_passou is not null then
    raise exception 'Voce passou a vez nesta sessao. As vagas foram liberadas para as proximas empresas.'
      using errcode = '55000';
  end if;

  if v_encerrada is not null then
    raise exception 'A escolha desta sessao ja foi encerrada.'
      using errcode = '55000';
  end if;

  -- janela vencida vem antes da vez: com 0 na frente, "nao e a sua vez"
  -- nao explicaria nada
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
-- 6. PERMISSAO
-- ---------------------------------------------------------------------
revoke execute on function _janelas_da_fila(uuid, text) from public, anon;
revoke execute on function _limite_da_janela(timestamptz, int, date, boolean) from public, anon;
grant execute on function _janelas_da_fila(uuid, text) to authenticated, service_role;
grant execute on function _limite_da_janela(timestamptz, int, date, boolean) to authenticated, service_role;
