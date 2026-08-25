-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Fatura complementar: cobrar a diferenca, nao o valor cheio.
--
-- O DEFEITO
--
-- `_recalcular_fatura_participante` so procura fatura com status
-- 'estimada'. Quando a anterior ja foi emitida ou paga, ela nao acha
-- nada e cria uma fatura NOVA com o valor cheio recalculado. O
-- acompanhante que ja foi pago aparece de novo na cobranca: o
-- participante paga duas vezes pela mesma pessoa.
--
-- Acontece sempre que o rooming muda depois de emitir — trocar de
-- quarto, acrescentar transfer, incluir uma crianca. Nao e caso raro:
-- e o fluxo normal de quem fecha a inscricao cedo.
--
-- `_recalcular_fatura_patrocinador` tem exatamente o mesmo defeito para
-- quarto extra e transfer, e vai junto.
--
-- A CORRECAO
--
-- A fatura emitida/paga continua intocada — isso ja estava certo e e a
-- regra do sistema ("emitir congela o valor"). O que muda e a estimada
-- nova: ela passa a nascer com uma linha de abatimento do que ja foi
-- faturado, entao o total dela e a DIFERENCA.
--
--   Acompanhante adulto        1 x  2.400,00     2.400,00
--   Transfer                   1 x    180,00       180,00
--   Já faturado anteriormente  1 x -2.400,00    -2.400,00
--   --------------------------------------------------
--   Total                                          180,00
--
-- A conta fecha por inducao: cada fatura emitida guarda uma parcela, e
-- a soma delas e o valor cheio ja cobrado. Por isso o abatimento soma
-- 'emitida' E 'paga'.
--
-- Se a diferenca der negativa (alguem tirou um acompanhante depois de
-- pagar), a fatura fica com total negativo de proposito: e credito
-- devido, e esconder isso e pior do que mostrar. O resumo financeiro
-- ja soma `total` das nao-pagas, entao o valor entra liquido em "em
-- aberto".
--
-- ORDEM: vem depois de 102100 (trava do anon) de proposito. Nao desfaz
-- a trava: `create or replace` preserva o ACL da funcao existente, e
-- nenhuma destas duas e chamada pelo front — sao internas, chamadas por
-- `admin_recalcular_faturas` e `part_calcular_fatura`, que sao SECURITY
-- DEFINER.
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
