-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- "Acompanhante" vira "familiar" em todo texto que o CIO/staff le.
--
-- O QUE MUDA E O QUE NAO MUDA
--
-- Muda: rotulo de tela, mensagem de erro, descricao de item de fatura
-- (o que a pessoa LE), e a categoria de cracha gravada em `ocupantes`
-- (o que a pessoa VE impresso no cracha na recepcao).
--
-- NAO muda: a chave interna do item de preco `acompanhante_adulto`
-- (coluna `precos.item`, lida por _item_do_ocupante/_preco_item em
-- meia duzia de funcoes), nem o nome das variaveis/parametros JS e SQL
-- (ACOMPANHANTES, p_acompanhantes). Sao identificador tecnico, ninguem
-- le — trocar so multiplicaria o risco de erro de digitacao numa
-- migration futura sem nenhum ganho pra quem usa a tela.
--
-- BACKFILL
--
-- `ocupantes.categoria_cracha` e `fatura_itens.descricao` ja tem gente
-- de verdade gravada com o texto antigo — sem backfill, cracha
-- impresso hoje ainda sairia "ACOMPANHANTE" e fatura ja emitida
-- continuaria com "Acompanhante adulto" na linha, incoerente com toda
-- tela nova.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. QUEM PREENCHE O PROPRIO ROOMING PASSA A GRAVAR "FAMILIAR"
-- ---------------------------------------------------------------------
create or replace function gestao.part_salvar_rooming(p_evento_slug text, p_acompanhantes jsonb, p_usa_transfer boolean DEFAULT NULL::boolean, p_transfer_origem text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare
  v_part   uuid;
  v_res    uuid;
  v_status jsonb;
  v_prazo  date;
  v_limite date;
  v_item   jsonb;
  v_nasc   date;
  v_qtd    int;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;

  perform _exige_origem_transfer(p_transfer_origem);

  v_status := part_meu_status(p_evento_slug);

  if not (v_status ->> 'rooming_liberado')::boolean then
    raise exception 'Rooming liberado apenas apos a assinatura do contrato'
      using errcode = '55000';
  end if;

  v_prazo := (v_status ->> 'prazo_rooming')::date;
  if v_prazo is not null and current_date > v_prazo and not is_staff() then
    raise exception 'Prazo de rooming encerrado em %', v_prazo
      using errcode = '55000';
  end if;

  v_qtd := jsonb_array_length(coalesce(p_acompanhantes,'[]'::jsonb)) + 1;
  if v_qtd > _capacidade_quarto() then
    raise exception
      'O quarto comporta % pessoa(s), incluindo voce; foram informadas %. Acima disso e quarto adicional.',
      _capacidade_quarto(), v_qtd using errcode = '22023';
  end if;

  select coalesce(e.data_inicio, current_date) into v_limite
  from eventos e where e.slug = p_evento_slug;

  for v_item in select * from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb))
  loop
    if coalesce(trim(v_item ->> 'nome'),'') = '' then
      raise exception 'Todo familiar precisa de nome' using errcode = '22023';
    end if;
    v_nasc := nullif(v_item ->> 'data_nascimento','')::date;
    if v_nasc is not null and v_nasc > v_limite then
      raise exception 'Data de nascimento depois do início do evento (%): %', v_limite, v_nasc
        using errcode = '22023';
    end if;
    perform _exige_origem_transfer(nullif(v_item ->> 'transfer_origem',''));
    if coalesce(v_item ->> 'tipo','adulto') = 'crianca' and v_nasc is null then
      raise exception 'Informe a data de nascimento das criancas'
        using errcode = '22023';
    end if;
  end loop;

  v_res := _garantir_reserva(v_part);

  delete from ocupantes where reserva_id = v_res and tipo <> 'titular';

  insert into ocupantes (reserva_id, nome, cpf, data_nascimento, tipo,
                         usa_transfer, transfer_origem, categoria_cracha)
  select v_res,
         trim(x ->> 'nome'),
         nullif(x ->> 'cpf',''),
         nullif(x ->> 'data_nascimento','')::date,
         coalesce(nullif(x ->> 'tipo',''), 'adulto'),
         (x ->> 'usa_transfer')::boolean,
         nullif(x ->> 'transfer_origem',''),
         'FAMILIAR'
  from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb)) x;

  insert into ocupantes (reserva_id, nome, tipo, categoria_cracha, email)
  select v_res, g.nome, 'titular', 'PROTAGONISTA', g.email
  from participantes pa join gestores g on g.id = pa.gestor_id
  where pa.id = v_part
    and not exists (select 1 from ocupantes o
                    where o.reserva_id = v_res and o.tipo = 'titular');

  update ocupantes set
    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),
    transfer_origem = coalesce(p_transfer_origem, transfer_origem)
   where reserva_id = v_res and tipo = 'titular';

  update reservas set
    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),
    transfer_origem = coalesce(p_transfer_origem, transfer_origem),
    status          = 'completo',
    completo_em     = coalesce(completo_em, now())
  where id = v_res;

  insert into notificacoes (evento_id, destinatario, tipo, assunto)
  select r.evento_id, g.email, 'rooming_ok', 'Dados de hospedagem confirmados'
  from reservas r
  join participantes pa on pa.id = r.participante_id
  join gestores g on g.id = pa.gestor_id
  where r.id = v_res;

  return part_calcular_fatura(p_evento_slug);
end;
$function$;

-- ---------------------------------------------------------------------
-- 2. AS DUAS FUNCOES QUE TEXTUALIZAM A LINHA DA FATURA
-- ---------------------------------------------------------------------
create or replace function gestao.part_previa_fatura(p_evento_slug text, p_acompanhantes jsonb, p_usa_transfer boolean DEFAULT false)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'gestao', 'public'
as $function$
declare
  v_part uuid; v_evento uuid; v_limite date;
  v_total numeric(12,2) := 0;
  v_valor numeric(12,2);
  v_itens jsonb := '[]'::jsonb;
  v_transf int := 0;
  v_linha record;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode='P0002';
  end if;
  select evento_id into v_evento from participantes where id = v_part;
  select coalesce(data_inicio, current_date) into v_limite from eventos where id = v_evento;

  for v_linha in
    with base as (
      select ordinalidade,
             coalesce(nullif(x ->> 'tipo',''), 'adulto') as tipo,
             case
               when nullif(x ->> 'data_nascimento','')::date > v_limite then null
               else _idade_no_evento(v_evento, nullif(x ->> 'data_nascimento','')::date)
             end as idade,
             coalesce((x ->> 'usa_transfer')::boolean, false) as transfer
      from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb))
           with ordinality as t(x, ordinalidade)
    ),
    marcado as (
      select b.*,
             _item_do_ocupante(b.tipo) as item,
             _item_do_ocupante(b.tipo) = 'acompanhante_adulto'
               and row_number() over (
                     partition by _item_do_ocupante(b.tipo)
                     order by _preco_item(v_evento, _item_do_ocupante(b.tipo), b.idade) desc,
                              b.ordinalidade
                   ) <= _cortesia_acompanhante() as cortesia
      from base b
    )
    select * from marcado order by ordinalidade
  loop
    v_valor := case when v_linha.cortesia then 0
                    else _preco_item(v_evento, v_linha.item, v_linha.idade) end;
    v_total := v_total + v_valor;

    v_itens := v_itens || jsonb_build_object(
      'descricao',
        (case when v_linha.tipo = 'crianca' then 'Criança' else 'Familiar adulto' end
         || case when v_linha.idade is not null then ' · ' || v_linha.idade || ' anos' else '' end
         || case when v_linha.cortesia then ' · cortesia' else '' end),
      'valor', v_valor);

    if v_linha.transfer then
      v_valor := _preco_item(v_evento, 'transfer', v_linha.idade);
      v_total := v_total + v_valor;
      v_transf := v_transf + 1;
    end if;
  end loop;

  if p_usa_transfer then
    v_valor := _preco_item(v_evento, 'transfer', null);
    v_total := v_total + v_valor;
    v_transf := v_transf + 1;
  end if;

  if v_transf > 0 then
    v_itens := v_itens || jsonb_build_object(
      'descricao', 'Transfer × ' || v_transf, 'valor', null);
  end if;

  return jsonb_build_object('total', v_total, 'itens', v_itens,
                            'transfers', v_transf);
end;
$function$;

create or replace function gestao._recalcular_fatura_participante(p_participante_id uuid)
 returns numeric
 language plpgsql
 security definer
 set search_path to 'gestao', 'public'
as $function$
declare
  v_evento uuid; v_res uuid; v_fatura uuid;
  v_total numeric(12,2) := 0; v_linha record;
  v_pt numeric(12,2); v_travada numeric(12,2);
begin
  perform _exige_participante(p_participante_id);

  select evento_id into v_evento from participantes where id = p_participante_id;
  if v_evento is null then return 0; end if;

  select id into v_res from reservas
   where participante_id = p_participante_id and status <> 'cancelado';
  if v_res is null then return 0; end if;

  select total into v_travada from faturas
   where participante_id = p_participante_id and status in ('emitida','paga');
  if v_travada is not null then
    return v_travada;
  end if;

  select id into v_fatura from faturas
   where participante_id = p_participante_id and status = 'estimada';

  if v_fatura is null then
    insert into faturas (evento_id, participante_id, status)
    values (v_evento, p_participante_id, 'estimada')
    returning id into v_fatura;
  else
    delete from fatura_itens where fatura_id = v_fatura;
  end if;

  for v_linha in
    with base as (
      select o.id,
             _item_do_ocupante(o.tipo) as item,
             _idade_no_evento(v_evento, o.data_nascimento) as idade
      from ocupantes o
      where o.reserva_id = v_res and o.tipo <> 'titular'
    ),
    marcado as (
      select b.*,
             b.item = 'acompanhante_adulto'
               and row_number() over (
                     partition by b.item
                     order by _preco_item(v_evento, b.item, b.idade) desc, b.id
                   ) <= _cortesia_acompanhante() as cortesia
      from base b
    )
    select item, idade, cortesia, count(*) as qtd
    from marcado
    group by 1, 2, 3
  loop
    declare
      v_valor numeric(12,2) := _preco_item(v_evento, v_linha.item, v_linha.idade);
      v_desc text;
    begin
      v_desc := case when v_linha.item = 'crianca' then 'Criança' else 'Familiar adulto' end
              || case when v_linha.idade is not null
                      then ' · ' || v_linha.idade || ' anos' else '' end;

      if v_linha.cortesia then
        insert into fatura_itens (fatura_id, reserva_id, descricao,
                                  quantidade, valor_unit)
        values (v_fatura, v_res, v_desc || ' · cortesia', v_linha.qtd, 0);
      elsif v_valor > 0 then
        insert into fatura_itens (fatura_id, reserva_id, descricao,
                                  quantidade, valor_unit)
        values (v_fatura, v_res, v_desc, v_linha.qtd, v_valor);
        v_total := v_total + v_linha.qtd * v_valor;
      end if;
    end;
  end loop;

  for v_linha in
    select _idade_no_evento(v_evento, o.data_nascimento) as idade,
           count(*) as qtd
    from ocupantes o
    where o.reserva_id = v_res and o.usa_transfer
    group by 1
  loop
    v_pt := _preco_item(v_evento, 'transfer', v_linha.idade);
    if v_pt > 0 then
      insert into fatura_itens (fatura_id, reserva_id, descricao,
                                quantidade, valor_unit)
      values (v_fatura, v_res,
              'Transfer' || case when v_linha.idade is not null
                                 then ' · ' || v_linha.idade || ' anos' else '' end,
              v_linha.qtd, v_pt);
      v_total := v_total + v_linha.qtd * v_pt;
    end if;
  end loop;

  update faturas set total = v_total where id = v_fatura;
  return v_total;
end;
$function$;

-- ---------------------------------------------------------------------
-- 3. AS DUAS VIEWS QUE ROTULAM O CRACHA
-- ---------------------------------------------------------------------
create or replace view v_etiquetas as
 SELECT r.evento_id,
    ('ocupante:'::text || (o.id)::text) AS pessoa_key,
    q.numero AS apto,
    o.nome,
    COALESCE(p.empresa, g.empresa) AS empresa,
        CASE
            WHEN ((o.data_nascimento IS NOT NULL) AND (age((o.data_nascimento)::timestamp without time zone) < '21 years'::interval)) THEN 'S/CRACHA'::text
            ELSE COALESCE(o.categoria_cracha,
            CASE
                WHEN (r.patrocinador_id IS NOT NULL) THEN 'PATROCINADOR'::text
                WHEN (o.tipo = 'titular'::text) THEN 'PROTAGONISTA'::text
                ELSE 'FAMILIAR'::text
            END)
        END AS categoria,
    'quarto'::text AS origem
   FROM (((("gestao"."ocupantes" o
     JOIN "gestao"."reservas" r ON (((r.id = o.reserva_id) AND (r.status <> 'cancelado'::text))))
     LEFT JOIN "gestao"."quartos" q ON ((q.id = r.quarto_id)))
     LEFT JOIN "gestao"."patrocinadores" p ON ((p.id = r.patrocinador_id)))
     LEFT JOIN "gestao"."participantes" pa ON ((pa.id = r.participante_id)))
     LEFT JOIN "gestao"."gestores" g ON ((g.id = pa.gestor_id))
UNION ALL
 SELECT pa.evento_id,
    ('participante:'::text || (pa.id)::text) AS pessoa_key,
    NULL::text AS apto,
    g.nome,
    g.empresa,
    'PROTAGONISTA'::text AS categoria,
    'inscricao'::text AS origem
   FROM ("gestao"."participantes" pa
     JOIN "gestao"."gestores" g ON ((g.id = pa.gestor_id)))
  WHERE ((pa.status = 'aprovado'::text) AND (NOT (EXISTS ( SELECT 1
           FROM "gestao"."reservas" r
          WHERE ((r.participante_id = pa.id) AND (r.status <> 'cancelado'::text))))))
UNION ALL
 SELECT p.evento_id,
    ('usuario_patro:'::text || (u.id)::text) AS pessoa_key,
    NULL::text AS apto,
    COALESCE(u.nome, "split_part"(u.email, '@'::text, 1)) AS nome,
    p.empresa,
    'PATROCINADOR'::text AS categoria,
    'patrocinador'::text AS origem
   FROM ("gestao"."usuarios_patrocinador" u
     JOIN "gestao"."patrocinadores" p ON ((p.id = u.patrocinador_id)))
  WHERE (u.ativo AND (p.status = 'ativo'::text) AND (NOT (EXISTS ( SELECT 1
           FROM "gestao"."reservas" r
          WHERE ((r.patrocinador_id = p.id) AND (r.status <> 'cancelado'::text))))));

create or replace view v_esperados as
 SELECT r.evento_id,
    ('ocupante:'::text || (o.id)::text) AS pessoa_key,
    o.nome,
    COALESCE(p.empresa, g.empresa) AS empresa,
    COALESCE(o.categoria_cracha,
        CASE
            WHEN (r.patrocinador_id IS NOT NULL) THEN 'PATROCINADOR'::text
            WHEN (o.tipo = 'titular'::text) THEN 'PROTAGONISTA'::text
            ELSE 'FAMILIAR'::text
        END) AS categoria,
    q.numero AS quarto,
    r.patrocinador_id,
    COALESCE(o.email, g.email) AS email
   FROM (((("gestao"."ocupantes" o
     JOIN "gestao"."reservas" r ON (((r.id = o.reserva_id) AND (r.status <> 'cancelado'::text))))
     LEFT JOIN "gestao"."quartos" q ON ((q.id = r.quarto_id)))
     LEFT JOIN "gestao"."patrocinadores" p ON ((p.id = r.patrocinador_id)))
     LEFT JOIN "gestao"."participantes" pa ON ((pa.id = r.participante_id)))
     LEFT JOIN "gestao"."gestores" g ON ((g.id = pa.gestor_id))
UNION ALL
 SELECT pa.evento_id,
    ('participante:'::text || (pa.id)::text) AS pessoa_key,
    g.nome,
    g.empresa,
    COALESCE(NULLIF(g.perfil, ''::text), 'PROTAGONISTA'::text) AS categoria,
    NULL::text AS quarto,
    NULL::uuid AS patrocinador_id,
    g.email
   FROM ("gestao"."participantes" pa
     JOIN "gestao"."gestores" g ON ((g.id = pa.gestor_id)))
  WHERE ((pa.status = 'aprovado'::text) AND (NOT (EXISTS ( SELECT 1
           FROM "gestao"."reservas" r
          WHERE ((r.participante_id = pa.id) AND (r.status <> 'cancelado'::text))))))
UNION ALL
 SELECT p.evento_id,
    ('usuario_patro:'::text || (u.id)::text) AS pessoa_key,
    COALESCE(u.nome, "split_part"(u.email, '@'::text, 1)) AS nome,
    p.empresa,
    'PATROCINADOR'::text AS categoria,
    NULL::text AS quarto,
    p.id AS patrocinador_id,
    u.email
   FROM ("gestao"."usuarios_patrocinador" u
     JOIN "gestao"."patrocinadores" p ON ((p.id = u.patrocinador_id)))
  WHERE (u.ativo AND (p.status = 'ativo'::text) AND (NOT (EXISTS ( SELECT 1
           FROM "gestao"."reservas" r
          WHERE ((r.patrocinador_id = p.id) AND (r.status <> 'cancelado'::text))))));

-- ---------------------------------------------------------------------
-- 4. BACKFILL: quem ja esta gravado com o texto antigo
-- ---------------------------------------------------------------------
update ocupantes set categoria_cracha = 'FAMILIAR' where categoria_cracha = 'ACOMPANHANTE';

update fatura_itens set descricao = replace(descricao, 'Acompanhante adulto', 'Familiar adulto')
 where descricao like 'Acompanhante adulto%';
