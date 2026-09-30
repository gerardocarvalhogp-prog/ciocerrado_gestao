-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- O custo de "entrega de brinde no quarto" contava os quartos do
-- PROPRIO patrocinador (reservas.patrocinador_id) — errado: o brinde
-- e entregue nos quartos dos CIOs, nao nos quartos que o patrocinador
-- tem por causa da propria cota. Pedido do organizador em 30/09/2026,
-- confirmado: conta TODO quarto de CIO do evento (toda reserva com
-- participante_id preenchido, nao cancelada) — o mesmo numero pra
-- qualquer patrocinador que mandar brinde pro quarto, independente de
-- quem ele indicou.
--
-- Muda so a consulta que conta "quartos" nas duas funcoes que usam
-- esse numero — patro_prever_custo_brinde (previa, antes de
-- confirmar) e _recalcular_fatura_patrocinador (cobranca de verdade).
-- O resto de cada funcao fica identico ao texto vigente
-- (20260901140000_varios_brindes_por_empresa.sql e
-- 20260826110000_brinde_da_empresa.sql).
-- =====================================================================

set search_path = gestao, public;

create or replace function patro_prever_custo_brinde(p_patrocinador_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_quartos int; v_preco numeric(12,2); v_evento uuid;
begin
  perform _exige_patrocinador(p_patrocinador_id);
  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;

  -- quarto de CIO = reserva de participante (rooming da inscricao),
  -- nao reserva do patrocinador. Conta todo mundo do evento, nao so
  -- quem esse patrocinador indicou.
  select count(*) into v_quartos from reservas r
   where r.evento_id = v_evento and r.participante_id is not null and r.status <> 'cancelado';

  v_preco := _preco_item(v_evento, 'entrega_brinde_quarto');
  return jsonb_build_object('quartos', v_quartos, 'preco_entrega', v_preco,
                            'custo_se_quarto', v_quartos * v_preco);
end;
$$;

CREATE OR REPLACE FUNCTION gestao._recalcular_fatura_patrocinador(p_patrocinador_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_evento uuid; v_fatura uuid; v_total numeric(12,2) := 0;
  v_linha record; v_pt numeric(12,2);
  v_travada numeric(12,2);
begin
  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;
  if v_evento is null then return 0; end if;

  -- emitida/paga esta congelada: recalculo automatico para aqui.
  select total into v_travada from faturas
   where patrocinador_id = p_patrocinador_id and status in ('emitida','paga');
  if v_travada is not null then
    return v_travada;
  end if;

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

  -- Entrega no quarto e servico do resort, cobrado por porta: e
  -- camareira subindo com caixa. No stand nao ha custo — o brinde fica
  -- na mesa e quem quer, pega.
  --
  -- Quarto de CIO = reserva de participante, nao reserva do
  -- patrocinador — o brinde vai pro quarto de quem vai ficar
  -- hospedado como CIO, nao pro quarto que o patrocinador tem pela
  -- propria cota. Conta todo quarto de CIO do evento, nao so quem
  -- esse patrocinador indicou (30/09/2026).
  if exists (select 1 from brindes b
              where b.patrocinador_id = p_patrocinador_id
                and b.vai_enviar and b.destino = 'quarto') then
    declare
      v_quartos int;
      v_ve numeric(12,2) := _preco_item(v_evento, 'entrega_brinde_quarto');
    begin
      select count(*) into v_quartos from reservas r
       where r.evento_id = v_evento and r.participante_id is not null and r.status <> 'cancelado';
      if v_ve > 0 and v_quartos > 0 then
        insert into fatura_itens (fatura_id, descricao, quantidade, valor_unit)
        values (v_fatura, 'Entrega de brinde no quarto', v_quartos, v_ve);
        v_total := v_total + v_quartos * v_ve;
      end if;
    end;
  end if;

  update faturas set total = v_total where id = v_fatura;

  if v_total = 0 then
    delete from fatura_itens where fatura_id = v_fatura;
    delete from faturas where id = v_fatura;
  end if;

  return v_total;
end;
$function$;
