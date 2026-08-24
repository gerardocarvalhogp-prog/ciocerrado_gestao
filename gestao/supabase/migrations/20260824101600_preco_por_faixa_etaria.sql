-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- migracao-03.sql  ·  preco por faixa etaria
--
-- Rodar DEPOIS de funcoes-financeiro.sql.
--
-- Ate aqui "crianca" tinha um preco so. Hotel cobra por faixa: ate 5
-- cortesia, 6 a 11 meia, 12 em diante inteira. Agora cada item pode ter
-- varias faixas.
--
-- A idade considerada e a do INICIO DO EVENTO, nao a de hoje. Uma
-- crianca que faz 12 anos entre a inscricao e o check-in entra na faixa
-- de 12 — e assim que o resort cobra.
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 1. ESTRUTURA
-- =====================================================================

alter table precos add column if not exists idade_min int;
alter table precos add column if not exists idade_max int;

-- O mesmo item passa a ter varias linhas, uma por faixa.
drop index if exists precos_uk;
create unique index if not exists precos_faixa_uk
  on precos(evento_id, item, coalesce(idade_min, -1), coalesce(idade_max, 999));

alter table precos drop constraint if exists precos_faixa_ck;
alter table precos add constraint precos_faixa_ck
  check (idade_min is null or idade_max is null or idade_max >= idade_min);

-- =====================================================================
-- 2. IDADE E BUSCA DE PRECO
-- =====================================================================

-- Idade que a pessoa tera no inicio do evento. Sem data de inicio
-- cadastrada, cai para a data de hoje.
create or replace function _idade_no_evento(p_evento uuid, p_nascimento date)
returns int language sql stable security definer
set search_path = gestao, public as $$
  select case
    when p_nascimento is null then null
    else extract(year from age(
      coalesce((select data_inicio from eventos where id = p_evento), current_date),
      p_nascimento))::int
  end;
$$;

-- Preco do item para uma idade. Procura primeiro a faixa que contem a
-- idade; se nao achar, usa a linha sem faixa definida (preco unico).
create or replace function _preco_item(
  p_evento uuid, p_item text, p_idade int default null
) returns numeric language sql stable security definer
set search_path = gestao, public as $$
  select coalesce(
    (select pr.valor from precos pr
      where pr.evento_id = p_evento and pr.item = p_item
        and p_idade is not null
        and coalesce(pr.idade_min, 0)   <= p_idade
        and coalesce(pr.idade_max, 999) >= p_idade
      -- faixa mais especifica ganha da generica
      order by (pr.idade_min is not null) desc, pr.idade_min desc
      limit 1),
    (select pr.valor from precos pr
      where pr.evento_id = p_evento and pr.item = p_item
        and pr.idade_min is null and pr.idade_max is null
      limit 1),
    0);
$$;

-- Rotulo da faixa, para a fatura dizer por que aquele valor.
create or replace function _rotulo_faixa(p_min int, p_max int)
returns text language sql immutable as $$
  select case
    when p_min is null and p_max is null then ''
    when p_min is null then ' (até ' || p_max || ' anos)'
    when p_max is null then ' (' || p_min || ' anos ou mais)'
    else ' (' || p_min || ' a ' || p_max || ' anos)'
  end;
$$;

-- Item de preco usado por um ocupante.
create or replace function _item_do_ocupante(p_tipo text)
returns text language sql immutable as $$
  select case when p_tipo = 'crianca' then 'crianca'
              else 'acompanhante_adulto' end;
$$;

-- =====================================================================
-- 3. CADASTRO DE PRECOS COM FAIXA
--
-- DROP antes do CREATE OR REPLACE: admin_listar_precos ganha colunas
-- novas (idade_min, idade_max, faixa) e o Postgres nao troca o formato
-- de saida so com REPLACE quando isso muda (erro 42P13).
-- =====================================================================

drop function if exists admin_listar_precos(text);

create or replace function admin_listar_precos(p_evento_slug text)
returns table (id uuid, item text, descricao text, valor numeric,
               idade_min int, idade_max int, faixa text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select pr.id, pr.item, pr.descricao, pr.valor,
           pr.idade_min, pr.idade_max,
           _rotulo_faixa(pr.idade_min, pr.idade_max)
    from precos pr
    join eventos e on e.id = pr.evento_id and e.slug = p_evento_slug
    order by pr.item, pr.idade_min nulls first;
end;
$$;

create or replace function admin_salvar_preco(
  p_evento_slug text,
  p_item text,
  p_valor numeric,
  p_descricao text default null,
  p_idade_min int default null,
  p_idade_max int default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_item text; v_conflito text;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;

  v_item := trim(both '_' from regexp_replace(
    lower(unaccent('unaccent', coalesce(trim(p_item),''))), '[^a-z0-9]+','_','g'));

  if v_item = '' then
    raise exception 'Informe o item' using errcode='22023';
  end if;
  if p_valor is null or p_valor < 0 then
    raise exception 'Valor invalido' using errcode='22023';
  end if;
  if p_idade_min is not null and p_idade_max is not null
     and p_idade_max < p_idade_min then
    raise exception 'A idade final e menor que a inicial' using errcode='22023';
  end if;

  -- Faixas que se cruzam tornam o preco ambiguo: "0 a 11" e "6 a 12"
  -- deixariam a crianca de 8 anos com dois valores possiveis.
  if p_idade_min is not null or p_idade_max is not null then
    select _rotulo_faixa(pr.idade_min, pr.idade_max) into v_conflito
    from precos pr
    where pr.evento_id = v_evento and pr.item = v_item
      and (pr.idade_min is not null or pr.idade_max is not null)
      and coalesce(pr.idade_min,0)   <= coalesce(p_idade_max,999)
      and coalesce(pr.idade_max,999) >= coalesce(p_idade_min,0)
      and not (coalesce(pr.idade_min,-1) = coalesce(p_idade_min,-1)
               and coalesce(pr.idade_max,999) = coalesce(p_idade_max,999))
    limit 1;

    if v_conflito is not null then
      raise exception 'Esta faixa se sobrepõe à faixa%', v_conflito
        using errcode='23505';
    end if;
  end if;

  insert into precos (evento_id, item, descricao, valor, idade_min, idade_max)
  values (v_evento, v_item, p_descricao, p_valor, p_idade_min, p_idade_max)
  on conflict (evento_id, item, coalesce(idade_min,-1), coalesce(idade_max,999))
  do update set valor = excluded.valor,
                descricao = coalesce(excluded.descricao, precos.descricao);

  return jsonb_build_object('ok', true, 'item', v_item,
                            'faixa', _rotulo_faixa(p_idade_min, p_idade_max));
end;
$$;

-- Agora so bloqueia a remocao quando e a ULTIMA linha do item: apagar
-- uma faixa entre varias e operacao normal.
create or replace function admin_remover_preco(p_preco_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_item text; v_evento uuid; v_restam int;
begin
  perform _exige_admin();

  select item, evento_id into v_item, v_evento from precos where id = p_preco_id;
  if v_item is null then
    raise exception 'Preco nao encontrado' using errcode='P0002';
  end if;

  select count(*) into v_restam from precos
   where evento_id = v_evento and item = v_item and id <> p_preco_id;

  if v_restam = 0 and v_item in ('acompanhante_adulto','crianca','transfer') then
    raise exception
      'O item "%" e usado no calculo da fatura. Para nao cobrar, deixe o valor em zero.',
      v_item using errcode='42501';
  end if;

  delete from precos where id = p_preco_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- =====================================================================
-- 4. FATURAS COM FAIXA ETARIA
--
-- O calculo deixa de contar por tipo e passa a agrupar por (item,
-- faixa): duas criancas de idades diferentes viram duas linhas.
-- =====================================================================

create or replace function _recalcular_fatura_participante(p_participante_id uuid)
returns numeric language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_res uuid; v_fatura uuid;
  v_total numeric(12,2) := 0; v_linha record;
  v_transfers int; v_pt numeric(12,2);
begin
  select evento_id into v_evento from participantes where id = p_participante_id;
  if v_evento is null then return 0; end if;

  select id into v_res from reservas
   where participante_id = p_participante_id and status <> 'cancelado';
  if v_res is null then return 0; end if;

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
    select _item_do_ocupante(o.tipo) as item,
           _idade_no_evento(v_evento, o.data_nascimento) as idade,
           count(*) as qtd
    from ocupantes o
    where o.reserva_id = v_res and o.tipo <> 'titular'
    group by 1, 2
  loop
    declare
      v_valor numeric(12,2) := _preco_item(v_evento, v_linha.item, v_linha.idade);
      v_desc text;
    begin
      -- descricao carrega a idade: sem isso o cliente ve duas linhas
      -- "Criança" com valores diferentes e nao entende
      v_desc := case when v_linha.item = 'crianca' then 'Criança' else 'Acompanhante adulto' end
              || case when v_linha.idade is not null
                      then ' · ' || v_linha.idade || ' anos' else '' end;

      if v_valor > 0 then
        insert into fatura_itens (fatura_id, reserva_id, descricao,
                                  quantidade, valor_unit)
        values (v_fatura, v_res, v_desc, v_linha.qtd, v_valor);
        v_total := v_total + v_linha.qtd * v_valor;
      end if;
    end;
  end loop;

  -- transfer tambem pode ter faixa (crianca de colo nao paga)
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
$$;

create or replace function _recalcular_fatura_patrocinador(p_patrocinador_id uuid)
returns numeric language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_fatura uuid; v_total numeric(12,2) := 0;
  v_linha record; v_pt numeric(12,2);
begin
  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;
  if v_evento is null then return 0; end if;

  select id into v_fatura from faturas
   where patrocinador_id = p_patrocinador_id and status = 'estimada';

  if v_fatura is null then
    insert into faturas (evento_id, patrocinador_id, status)
    values (v_evento, p_patrocinador_id, 'estimada')
    returning id into v_fatura;
  else
    delete from fatura_itens where fatura_id = v_fatura;
  end if;

  for v_linha in
    select r.tipo, count(*) as qtd
    from reservas r
    where r.patrocinador_id = p_patrocinador_id
      and r.origem = 'extra' and r.status <> 'cancelado'
    group by r.tipo
  loop
    declare v_v numeric(12,2) := _preco_item(v_evento, 'quarto_' || v_linha.tipo);
    begin
      if v_v > 0 then
        insert into fatura_itens (fatura_id, descricao, quantidade, valor_unit)
        values (v_fatura, 'Quarto extra ' || v_linha.tipo, v_linha.qtd, v_v);
        v_total := v_total + v_linha.qtd * v_v;
      end if;
    end;
  end loop;

  for v_linha in
    select _idade_no_evento(v_evento, o.data_nascimento) as idade,
           count(*) as qtd
    from ocupantes o
    join reservas r on r.id = o.reserva_id and r.status <> 'cancelado'
    where r.patrocinador_id = p_patrocinador_id and o.usa_transfer
    group by 1
  loop
    v_pt := _preco_item(v_evento, 'transfer', v_linha.idade);
    if v_pt > 0 then
      insert into fatura_itens (fatura_id, descricao, quantidade, valor_unit)
      values (v_fatura, 'Transfer', v_linha.qtd, v_pt);
      v_total := v_total + v_linha.qtd * v_pt;
    end if;
  end loop;

  update faturas set total = v_total where id = v_fatura;

  if v_total = 0 then
    delete from fatura_itens where fatura_id = v_fatura;
    delete from faturas where id = v_fatura;
  end if;

  return v_total;
end;
$$;

-- =====================================================================
-- 5. TELA DO PARTICIPANTE
-- =====================================================================

create or replace function part_calcular_fatura(p_evento_slug text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_part uuid; v_total numeric(12,2); v_fatura uuid;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode='P0002';
  end if;

  v_total := _recalcular_fatura_participante(v_part);

  select id into v_fatura from faturas
   where participante_id = v_part and status = 'estimada';

  return jsonb_build_object(
    'total', coalesce(v_total,0),
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object(
        'descricao', fi.descricao, 'quantidade', fi.quantidade,
        'valor_unit', fi.valor_unit, 'valor_total', fi.valor_total))
      from fatura_itens fi where fi.fatura_id = v_fatura), '[]'::jsonb));
end;
$$;

-- Previa enquanto a pessoa digita. Recebe a data de nascimento de cada
-- acompanhante e usa a mesma tabela de faixas do calculo definitivo,
-- para o valor da tela nunca divergir do cobrado.
create or replace function part_previa_fatura(
  p_evento_slug text,
  p_acompanhantes jsonb,
  p_usa_transfer boolean default false
) returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare
  v_part uuid; v_evento uuid;
  v_total numeric(12,2) := 0;
  v_item jsonb; v_idade int; v_valor numeric(12,2);
  v_itens jsonb := '[]'::jsonb;
  v_nasc date; v_tipo text; v_transf int := 0;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode='P0002';
  end if;
  select evento_id into v_evento from participantes where id = v_part;

  for v_item in select * from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb))
  loop
    v_nasc := nullif(v_item ->> 'data_nascimento','')::date;
    v_tipo := coalesce(nullif(v_item ->> 'tipo',''), 'adulto');
    v_idade := _idade_no_evento(v_evento, v_nasc);
    v_valor := _preco_item(v_evento, _item_do_ocupante(v_tipo), v_idade);

    v_total := v_total + v_valor;
    v_itens := v_itens || jsonb_build_object(
      'descricao', case when v_tipo = 'crianca' then 'Criança' else 'Acompanhante adulto' end
                 || case when v_idade is not null then ' · ' || v_idade || ' anos' else '' end,
      'valor', v_valor);

    if (v_item ->> 'usa_transfer')::boolean then
      v_valor := _preco_item(v_evento, 'transfer', v_idade);
      v_total := v_total + v_valor;
      v_transf := v_transf + 1;
    end if;
  end loop;

  -- o titular tambem paga transfer e nao vem no payload
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
$$;

grant execute on function
  _idade_no_evento(uuid, date), _preco_item(uuid, text, int),
  _rotulo_faixa(int, int), _item_do_ocupante(text),
  admin_listar_precos(text),
  admin_salvar_preco(text, text, numeric, text, int, int),
  admin_remover_preco(uuid),
  part_calcular_fatura(text),
  part_previa_fatura(text, jsonb, boolean)
to authenticated;

-- Assinatura antiga de 4 parametros ficaria orfa ao lado da nova.
drop function if exists admin_salvar_preco(text, text, numeric, text);

-- =====================================================================
-- 6. EXEMPLO DE FAIXAS  (descomente e ajuste os valores)
-- =====================================================================
-- select admin_salvar_preco('cerrado2027','crianca',   0.00,'Criança até 5 anos',  0,  5);
-- select admin_salvar_preco('cerrado2027','crianca', 250.00,'Criança de 6 a 11',    6, 11);
-- select admin_salvar_preco('cerrado2027','crianca', 500.00,'Criança 12 ou mais',  12, null);
