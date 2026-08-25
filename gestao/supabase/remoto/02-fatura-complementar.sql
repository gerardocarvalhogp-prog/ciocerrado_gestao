-- =====================================================================
-- CORRECAO PARA O BANCO HOSPEDADO  ·  fatura complementar
--
-- NAO e uma migration. O banco remoto seguiu um caminho proprio e as
-- migrations locais NAO devem ser aplicadas la (ver LEIA-ME.md desta
-- pasta). Este arquivo troca DUAS funcoes, e nada mais.
--
-- Corresponde a migration local 20260824102200_fatura_complementar.sql:
-- as duas funcoes tem corpo identico nas duas linhagens, conferido no
-- dump de 24/08/2026, entao a mesma correcao serve para as duas.
--
-- O DEFEITO (confirmado no remoto)
--
-- `_recalcular_fatura_participante` so procura fatura 'estimada'.
-- Quando a anterior ja foi emitida ou paga, cria uma fatura NOVA com o
-- valor cheio: o acompanhante ja pago e cobrado outra vez. Acontece
-- toda vez que o rooming muda depois de emitir.
--
-- `_recalcular_fatura_patrocinador` tem o mesmo defeito em quarto extra
-- e transfer, e vai junto.
--
-- A CORRECAO
--
-- A emitida/paga continua intocada. A estimada nova nasce com uma
-- linha de abatimento do que ja foi faturado, entao cobra a DIFERENCA:
--
--   Acompanhante adulto        1 x  2.400,00     2.400,00
--   Transfer                   1 x    180,00       180,00
--   Já faturado anteriormente  1 x -2.400,00    -2.400,00
--   --------------------------------------------------
--   Total                                          180,00
--
-- Diferenca negativa (tirou acompanhante depois de pagar) fica como
-- total negativo de proposito: e credito devido.
--
-- APLICAR
--   supabase db query --linked -f supabase/remoto/02-fatura-complementar.sql
--
-- ROLLBACK: o corpo anterior das duas funcoes esta no git, na migration
-- 20260824101600_preco_por_faixa_etaria.sql — e so aplicar aquele
-- trecho de volta.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. PARTICIPANTE
-- ---------------------------------------------------------------------
create or replace function _recalcular_fatura_participante(p_participante_id uuid)
returns numeric language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_res uuid; v_fatura uuid;
  v_total numeric(12,2) := 0; v_linha record;
  v_transfers int; v_pt numeric(12,2);
  v_ja numeric(12,2) := 0;
begin
  select evento_id into v_evento from participantes where id = p_participante_id;
  if v_evento is null then return 0; end if;

  select id into v_res from reservas
   where participante_id = p_participante_id and status <> 'cancelado';
  if v_res is null then return 0; end if;

  -- O que ja foi congelado. Emitida e paga entram as duas porque a
  -- propria cobranca complementar vira documento quando for emitida —
  -- na rodada seguinte ela conta aqui e a soma continua fechando.
  select coalesce(sum(total), 0) into v_ja
    from faturas
   where participante_id = p_participante_id
     and status in ('emitida','paga');

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

  -- A linha de abatimento fica visivel de proposito: o participante
  -- precisa ver a conta cheia e o que ja pagou, senao a complementar
  -- chega como um valor solto que ninguem sabe explicar.
  if v_ja <> 0 then
    insert into fatura_itens (fatura_id, reserva_id, descricao,
                              quantidade, valor_unit)
    values (v_fatura, v_res, 'Já faturado anteriormente', 1, -v_ja);
    v_total := v_total - v_ja;
  end if;

  update faturas set total = v_total where id = v_fatura;
  return v_total;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. PATROCINADOR
--
-- Mesmo defeito, mesma correcao. Aqui a fatura zerada e apagada no fim
-- (comportamento que ja existia): quando a diferenca da zero, nao sobra
-- cobranca fantasma de R$ 0,00 na aba Financeiro. Na do participante a
-- zerada continua existindo, porque a tela conta com ela para dizer
-- "sem custo adicional".
-- ---------------------------------------------------------------------
create or replace function _recalcular_fatura_patrocinador(p_patrocinador_id uuid)
returns numeric language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_fatura uuid; v_total numeric(12,2) := 0;
  v_linha record; v_pt numeric(12,2);
  v_ja numeric(12,2) := 0;
begin
  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;
  if v_evento is null then return 0; end if;

  select coalesce(sum(total), 0) into v_ja
    from faturas
   where patrocinador_id = p_patrocinador_id
     and status in ('emitida','paga');

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

  if v_ja <> 0 then
    insert into fatura_itens (fatura_id, descricao, quantidade, valor_unit)
    values (v_fatura, 'Já faturado anteriormente', 1, -v_ja);
    v_total := v_total - v_ja;
  end if;

  update faturas set total = v_total where id = v_fatura;

  if v_total = 0 then
    delete from fatura_itens where fatura_id = v_fatura;
    delete from faturas where id = v_fatura;
  end if;

  return v_total;
end;
$$;
