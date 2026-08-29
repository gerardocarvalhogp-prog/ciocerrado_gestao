-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Previa de custo tambem ignora nascimento depois do inicio do evento
-- Retorno de QA (Cowork, Rodada 2, 30/08/2026)
--
-- part_salvar_rooming ja recusa nascimento depois do inicio do evento
-- (20260829160000). part_previa_fatura, que roda a cada tecla digitada
-- para mostrar o custo estimado, nao tinha a mesma regra — por isso
-- exibia "Acompanhante adulto · -62 anos · cortesia" enquanto a pessoa
-- ainda estava digitando uma data. A previa nao deve travar com erro
-- a cada tecla (o usuario pode estar no meio de digitar); em vez
-- disso, trata a data impossivel como se estivesse vazia — mesmo
-- comportamento ja usado quando a data nao foi informada.
-- =====================================================================

set search_path = gestao, public;

CREATE OR REPLACE FUNCTION gestao.part_previa_fatura(p_evento_slug text, p_acompanhantes jsonb, p_usa_transfer boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
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
$function$;
