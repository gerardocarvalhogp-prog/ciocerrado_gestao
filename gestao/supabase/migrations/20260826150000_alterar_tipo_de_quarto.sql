-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Corrigir o tipo de quartos ja criados.
--
-- O inventario e criado por faixa de numeracao, com um tipo para a
-- faixa inteira: "201 a 279, duplo". Se o tipo sair errado — e sai, o
-- resort manda o mapa em PDF e alguem le a coluna trocada — nao havia
-- como consertar pela tela. Sobrava apagar e recriar, o que derruba a
-- alocacao ja feita.
--
-- A alteracao usa a MESMA faixa da criacao, porque e assim que o mapa
-- do resort vem: bloco de numeros com um tipo. Corrigir de dez em dez
-- pela lista seria transcrever o mesmo erro de novo.
--
-- O QUE ELA NAO FAZ
--
-- Nao mexe em `reservas.tipo`. O tipo da reserva e o que define o preco
-- do quarto extra na fatura do patrocinador; muda-lo e mudar quanto
-- alguem paga, e isso nao pode ser efeito colateral de arrumar o mapa
-- do hotel. Fica para uma tela propria, com o valor na frente.
--
-- Capacidade acompanha o tipo, porque hoje ela e derivada dele no
-- cadastro. Quem manda na lotacao e `_capacidade_quarto()`, igual para
-- todos — a coluna aqui e descritiva.
-- =====================================================================

set search_path = gestao, public;

create or replace function admin_alterar_tipo_quartos(
  p_evento_slug text,
  p_de text,
  p_ate text,
  p_tipo text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_n int; v_de int; v_ate int;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;

  if p_tipo not in ('single','duplo','triplo') then
    raise exception 'Tipo invalido: %. Use single, duplo ou triplo', p_tipo
      using errcode = '22023';
  end if;

  -- a numeracao e texto no banco (pode ter letra: "201A"), mas a faixa
  -- so faz sentido em numero. Quem tiver letra fica de fora e e
  -- corrigido um a um.
  v_de  := nullif(regexp_replace(coalesce(p_de,''),  '[^0-9]', '', 'g'), '')::int;
  v_ate := nullif(regexp_replace(coalesce(p_ate,''), '[^0-9]', '', 'g'), '')::int;

  if v_de is null or v_ate is null or v_ate < v_de then
    raise exception 'Faixa invalida: de % ate %', p_de, p_ate
      using errcode = '22023';
  end if;

  update quartos q set
    tipo = p_tipo,
    capacidade = case p_tipo when 'single' then 1 when 'duplo' then 2 else 3 end
  where q.evento_id = v_evento
    and q.numero ~ '^[0-9]+$'
    and q.numero::int between v_de and v_ate
    and q.tipo <> p_tipo;

  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'alterados', v_n,
                            'de', v_de, 'ate', v_ate, 'tipo', p_tipo);
end;
$$;

revoke execute on function admin_alterar_tipo_quartos(text, text, text, text) from public, anon;
grant execute on function admin_alterar_tipo_quartos(text, text, text, text) to authenticated, service_role;
