-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- admin_criar_faixa_quartos truncava numero de quarto com 4+ digitos.
--
-- Achado do teste 13 (05/10/2026), decisao do organizador: corrigir.
-- O numero era montado com lpad(v_n, 3, '0') — que no Postgres CORTA o
-- texto quando ele passa do tamanho pedido: 1301..1306 viravam todos
-- '130', so o primeiro entrava (on conflict do nothing) e a funcao
-- devolvia criados=1 sem erro. Vem do baseline (24/08). Agora completa
-- com zero ate 3 digitos e nunca encurta: 7 -> '007', 1301 -> '1301'.
--
-- Quarto ja criado com numero cortado nao e consertado aqui: nao da pra
-- saber de que numero ele veio. Se o hospedado tiver algum, recriar a
-- faixa resolve (os que faltavam entram, o '130' errado sobra pra
-- remover na mao).
-- =====================================================================

set search_path = gestao, public;

CREATE OR REPLACE FUNCTION gestao.admin_criar_faixa_quartos(p_evento_slug text, p_de integer, p_ate integer, p_tipo text, p_bloco text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare v_evento uuid; v_cap int; v_criados int := 0; v_n int; v_num text;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if p_tipo not in ('single','duplo','triplo','quadruplo') then
    raise exception 'Tipo invalido' using errcode='22023';
  end if;
  if p_de is null or p_ate is null or p_ate < p_de then
    raise exception 'Faixa invalida' using errcode='22023';
  end if;
  if p_ate - p_de > 500 then
    raise exception 'Faixa muito grande (maximo 500 por vez)'
      using errcode='22023';
  end if;

  v_cap := case p_tipo when 'single' then 1 when 'duplo' then 2
                when 'triplo' then 3 when 'quadruplo' then 4 else 3 end;

  for v_n in p_de .. p_ate loop
    -- lpad corta o que passa do tamanho pedido: lpad('1301', 3) = '130'.
    -- Completa com zero ate 3 digitos, mas nunca encurta.
    v_num := lpad(v_n::text, greatest(3, length(v_n::text)), '0');
    insert into quartos (evento_id, numero, tipo, capacidade, bloco, status)
    values (v_evento, v_num, p_tipo, v_cap, p_bloco, 'disponivel')
    on conflict do nothing;
    if found then v_criados := v_criados + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'criados', v_criados,
                            'faixa', p_de || '-' || p_ate);
end;
$function$;
