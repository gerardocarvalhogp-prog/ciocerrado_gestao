-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Duas regras de dinheiro que o teste real de 25-26/08 mostrou faltando.
--
-- 1. CORTESIA DE UM ACOMPANHANTE ADULTO
--
-- Cada CIO inscrito tem direito a um acompanhante adulto sem custo. O
-- segundo em diante paga. Ate agora todo acompanhante era cobrado, o
-- que cobra a mais de praticamente todo mundo — quase ninguem vem com
-- dois acompanhantes adultos, entao o erro atingia o caso comum.
--
-- A cortesia entra como LINHA VISIVEL na fatura, com valor zero, em vez
-- de simplesmente sumir. Quem recebe a conta precisa ver que ganhou —
-- se a linha some, o cliente conta as pessoas, ve uma a menos e liga
-- perguntando se esqueceram alguem.
--
-- Quando ha mais de um adulto, a cortesia vai para o MAIS CARO. Hoje o
-- acompanhante adulto tem preco unico e isso nao muda nada; se um dia
-- tiver faixa por idade, a regra ja esta do lado do cliente.
--
-- 2. CAPACIDADE DE QUATRO
--
-- O quarto do resort comporta ate 4 pessoas. Acima disso e quarto
-- adicional, que se compra a parte.
--
--   - `part_salvar_rooming` nao validava NADA: o CIO podia cadastrar
--     oito acompanhantes num quarto e o sistema aceitava calado.
--   - `patro_salvar_quarto` validava por tipo (single 1, duplo 2,
--     triplo 3), o que barrava arranjo legitimo.
--
-- O tipo do quarto passa a ser so rotulo de preco — e o que diferencia
-- quanto custa o quarto extra, nao quantas pessoas cabem.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. OS DOIS NUMEROS, CADA UM NUM LUGAR SO
-- ---------------------------------------------------------------------
create or replace function _capacidade_quarto(p_tipo text default null)
returns int language sql immutable
set search_path = gestao, public as $$
  -- O tipo entra como parametro de proposito: se um dia o resort tiver
  -- categoria com teto diferente, muda aqui e nada mais precisa saber.
  select 4;
$$;

create or replace function _cortesia_acompanhante()
returns int language sql immutable
set search_path = gestao, public as $$
  select 1;
$$;

comment on function _capacidade_quarto(text) is
  'Quantas pessoas cabem num quarto. Acima disso, quarto adicional.';
comment on function _cortesia_acompanhante() is
  'Quantos acompanhantes adultos cada CIO tem sem custo.';

-- ---------------------------------------------------------------------
-- 2. A FATURA DO PARTICIPANTE
--
-- Mantem intacto o comportamento de fatura congelada que veio de
-- 20260825110000: emitida/paga para o recalculo e devolve o valor
-- travado. So a contagem dos itens muda.
-- ---------------------------------------------------------------------
create or replace function _recalcular_fatura_participante(p_participante_id uuid)
returns numeric language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_res uuid; v_fatura uuid;
  v_total numeric(12,2) := 0; v_linha record;
  v_pt numeric(12,2); v_travada numeric(12,2);
begin
  select evento_id into v_evento from participantes where id = p_participante_id;
  if v_evento is null then return 0; end if;

  select id into v_res from reservas
   where participante_id = p_participante_id and status <> 'cancelado';
  if v_res is null then return 0; end if;

  -- emitida/paga esta congelada: recalculo automatico para aqui.
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
      -- descricao carrega a idade: sem isso o cliente ve duas linhas
      -- "Criança" com valores diferentes e nao entende
      v_desc := case when v_linha.item = 'crianca' then 'Criança' else 'Acompanhante adulto' end
              || case when v_linha.idade is not null
                      then ' · ' || v_linha.idade || ' anos' else '' end;

      if v_linha.cortesia then
        -- linha visivel de proposito, com zero: o cliente precisa ver
        -- que ganhou, senao conta as pessoas e acha que faltou uma
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

-- ---------------------------------------------------------------------
-- 3. A PREVIA, QUE PRECISA DAR O MESMO NUMERO
--
-- Se a previa e a fatura discordarem, o CIO ve um valor na tela e
-- recebe outro na cobranca. Por isso a cortesia entra aqui tambem, com
-- a mesma regra: o primeiro adulto, o mais caro.
-- ---------------------------------------------------------------------
create or replace function part_previa_fatura(
  p_evento_slug text,
  p_acompanhantes jsonb,
  p_usa_transfer boolean default false
) returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare
  v_part uuid; v_evento uuid;
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

  for v_linha in
    with base as (
      select ordinalidade,
             coalesce(nullif(x ->> 'tipo',''), 'adulto') as tipo,
             _idade_no_evento(v_evento, nullif(x ->> 'data_nascimento','')::date) as idade,
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
        (case when v_linha.tipo = 'crianca' then 'Criança' else 'Acompanhante adulto' end
         || case when v_linha.idade is not null then ' · ' || v_linha.idade || ' anos' else '' end
         || case when v_linha.cortesia then ' · cortesia' else '' end),
      'valor', v_valor);

    if v_linha.transfer then
      v_valor := _preco_item(v_evento, 'transfer', v_linha.idade);
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

-- ---------------------------------------------------------------------
-- 4. CAPACIDADE NO ROOMING DO CONVIDADO
--
-- As tres funcoes abaixo sao o texto EXATO que estava no banco, com um
-- remendo pontual cada. Reescrever a mao a partir de leitura parcial ja
-- tinha comido, na primeira tentativa, o `email` do titular, um insert
-- em `notificacoes` e o formato de retorno.
--
-- A checagem vem ANTES de apagar os ocupantes: recusar depois de apagar
-- deixaria o quarto vazio por causa de uma tentativa invalida.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gestao.part_salvar_rooming(p_evento_slug text, p_acompanhantes jsonb, p_usa_transfer boolean DEFAULT NULL::boolean, p_transfer_origem text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$

declare

  v_part   uuid;

  v_res    uuid;

  v_status jsonb;

  v_prazo  date;

  v_item   jsonb;

  v_nasc   date;
  v_qtd    int;

begin

  v_part := _meu_participante(p_evento_slug);

  if v_part is null then

    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';

  end if;



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



  -- +1 pelo titular, que nao vem no payload mas ocupa cama
  v_qtd := jsonb_array_length(coalesce(p_acompanhantes,'[]'::jsonb)) + 1;
  if v_qtd > _capacidade_quarto() then
    raise exception
      'O quarto comporta % pessoa(s), incluindo voce; foram informadas %. Acima disso e quarto adicional.',
      _capacidade_quarto(), v_qtd using errcode = '22023';
  end if;

  -- valida antes de apagar qualquer coisa

  for v_item in select * from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb))

  loop

    if coalesce(trim(v_item ->> 'nome'),'') = '' then

      raise exception 'Todo acompanhante precisa de nome' using errcode = '22023';

    end if;

    v_nasc := nullif(v_item ->> 'data_nascimento','')::date;

    if v_nasc is not null and v_nasc > current_date then

      raise exception 'Data de nascimento no futuro: %', v_nasc

        using errcode = '22023';

    end if;

    -- crianca precisa de data de nascimento: e o que define a cobranca

    -- e a regra de cracha (menor de 21 fica sem)

    if coalesce(v_item ->> 'tipo','adulto') = 'crianca' and v_nasc is null then

      raise exception 'Informe a data de nascimento das criancas'

        using errcode = '22023';

    end if;

  end loop;



  v_res := _garantir_reserva(v_part);



  -- preserva o titular; troca so os acompanhantes

  delete from ocupantes where reserva_id = v_res and tipo <> 'titular';



  insert into ocupantes (reserva_id, nome, cpf, data_nascimento, tipo,

                         usa_transfer, categoria_cracha)

  select v_res,

         trim(x ->> 'nome'),

         nullif(x ->> 'cpf',''),

         nullif(x ->> 'data_nascimento','')::date,

         coalesce(nullif(x ->> 'tipo',''), 'adulto'),

         (x ->> 'usa_transfer')::boolean,

         'ACOMPANHANTE'

  from jsonb_array_elements(coalesce(p_acompanhantes,'[]'::jsonb)) x;



  -- titular entra sozinho se ainda nao existe

  insert into ocupantes (reserva_id, nome, tipo, categoria_cracha, email)

  select v_res, g.nome, 'titular', 'PROTAGONISTA', g.email

  from participantes pa join gestores g on g.id = pa.gestor_id

  where pa.id = v_part

    and not exists (select 1 from ocupantes o

                    where o.reserva_id = v_res and o.tipo = 'titular');



  -- O transfer do titular vem no campo do formulario, nao na lista de

  -- acompanhantes. Sem gravar aqui, a fatura contaria um transfer a

  -- menos do que a previa mostrou na tela.

  update ocupantes set usa_transfer = coalesce(p_usa_transfer, usa_transfer)

   where reserva_id = v_res and tipo = 'titular';



  update reservas set

    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),

    transfer_origem = coalesce(p_transfer_origem, transfer_origem),

    status          = 'completo'

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
-- 5. CAPACIDADE NO QUARTO DO PATROCINADOR
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gestao.patro_salvar_quarto(p_reserva_id uuid, p_ocupantes jsonb, p_usa_transfer boolean DEFAULT NULL::boolean, p_transfer_origem text DEFAULT NULL::text, p_brinde_enviar boolean DEFAULT NULL::boolean, p_brinde_descricao text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$

declare

  v_patro uuid;

  v_tipo  text;

  v_cap   int;

  v_qtd   int;

  v_item  jsonb;

begin

  select patrocinador_id, tipo into v_patro, v_tipo

  from reservas where id = p_reserva_id and status <> 'cancelado';



  if v_patro is null then

    raise exception 'Reserva nao encontrada' using errcode = 'P0002';

  end if;

  perform _exige_patrocinador(v_patro);



  -- o tipo virou rotulo de preco: quem manda na lotacao e o teto do
  -- quarto, igual para todos
  v_cap := _capacidade_quarto(v_tipo);

  v_qtd := jsonb_array_length(coalesce(p_ocupantes, '[]'::jsonb));



  if v_qtd > v_cap then

    raise exception 'O quarto comporta % pessoa(s); voce enviou %. Acima disso e quarto adicional.',
      v_cap, v_qtd using errcode = '22023';

  end if;



  -- nome vazio nao entra: e o erro mais comum no preenchimento

  for v_item in select * from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb))

  loop

    if coalesce(trim(v_item ->> 'nome'), '') = '' then

      raise exception 'Todo ocupante precisa de nome' using errcode = '22023';

    end if;

  end loop;



  delete from ocupantes where reserva_id = p_reserva_id;



  insert into ocupantes (reserva_id, nome, cpf, data_nascimento, tipo,

                         usa_transfer, email, telefone, categoria_cracha)

  select

    p_reserva_id,

    trim(x ->> 'nome'),

    nullif(x ->> 'cpf',''),

    nullif(x ->> 'data_nascimento','')::date,

    coalesce(nullif(x ->> 'tipo',''), 'adulto'),

    (x ->> 'usa_transfer')::boolean,

    nullif(x ->> 'email',''),

    nullif(x ->> 'telefone',''),

    'PATROCINADOR'

  from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb)) x;



  update reservas set

    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),

    transfer_origem = coalesce(p_transfer_origem, transfer_origem),

    -- preenchido = tem gente. Exigir a capacidade cheia prenderia em

    -- rascunho o duplo ocupado por uma pessoa so, que e caso legitimo,

    -- e travaria o fechado_em (logo, a fila da mesa redonda).

    status          = case when v_qtd > 0 then 'completo' else 'rascunho' end

  where id = p_reserva_id;



  if p_brinde_enviar is not null or p_brinde_descricao is not null then

    insert into brindes (patrocinador_id, reserva_id, vai_enviar, descricao)

    values (v_patro, p_reserva_id, coalesce(p_brinde_enviar,false), p_brinde_descricao)

    on conflict do nothing;



    update brindes set

      vai_enviar = coalesce(p_brinde_enviar, vai_enviar),

      descricao  = coalesce(p_brinde_descricao, descricao)

    where reserva_id = p_reserva_id;

  end if;



  perform _recalcular_fechado(v_patro);



  return jsonb_build_object('ok', true, 'ocupantes', v_qtd, 'capacidade', v_cap);

end;

$function$;

-- A lista precisa mostrar a mesma capacidade que a validacao usa, senao
-- a tela promete 2 e o banco aceita 4.
CREATE OR REPLACE FUNCTION gestao.patro_listar_quartos(p_patrocinador_id uuid)
 RETURNS TABLE(reserva_id uuid, rotulo text, tipo text, origem text, capacidade integer, ocupantes integer, usa_transfer boolean, transfer_origem text, status text, quarto_numero text, brinde_vai_enviar boolean, brinde_descricao text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$

begin

  perform _exige_patrocinador(p_patrocinador_id);

  return query

    select

      r.id, r.rotulo, r.tipo, r.origem,

      _capacidade_quarto(r.tipo),

      (select count(*)::int from ocupantes o where o.reserva_id = r.id),

      r.usa_transfer, r.transfer_origem, r.status,

      q.numero,

      b.vai_enviar, b.descricao

    from reservas r

    left join quartos q on q.id = r.quarto_id

    left join brindes b on b.reserva_id = r.id

    where r.patrocinador_id = p_patrocinador_id

      and r.status <> 'cancelado'

    order by r.created_at;

end;

$function$;

-- ---------------------------------------------------------------------
-- 6. PERMISSAO
-- ---------------------------------------------------------------------
revoke execute on function _capacidade_quarto(text) from public, anon;
revoke execute on function _cortesia_acompanhante() from public, anon;
grant execute on function _capacidade_quarto(text) to authenticated, service_role;
grant execute on function _cortesia_acompanhante() to authenticated, service_role;
