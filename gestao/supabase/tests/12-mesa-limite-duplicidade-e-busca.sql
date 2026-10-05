-- =====================================================================
-- Mesa: limite de vagas, trava de duplicidade entre sessoes do mesmo
-- tipo, busca restrita a aprovados, e quarto quadruplo · gestao CIO
-- Cerrado
--
-- RODA EM TRANSACAO E DESFAZ TUDO NO FIM — mesmo padrao de 07. Pode
-- rodar contra um banco com dado dentro (precisa so' do evento
-- 'cerrado2027' com cotas cadastradas), quantas vezes quiser.
--
-- COBRE o que foi pedido e corrigido ao vivo em 01/10/2026, testando
-- teste2027, e que NUNCA tinha ganho teste automatizado (a bateria
-- parou em 11-staff-por-evento-leva-2.sql, de 31/08 — tudo migrado
-- depois, inclusive isto aqui, só foi validado manualmente):
--
--   1. admin_adicionar_convidado_sessao respeita sessoes.vagas
--      (20261001250000) — antes so' fazia insert, sem olhar vaga
--   2. admin_adicionar_convidado_sessao recusa o mesmo CIO confirmado
--      em DUAS sessoes do MESMO TIPO (20261001260000) — so' nao pode
--      repetir o tipo: mesa_redonda e jantar sao coisas diferentes,
--      o mesmo CIO pode estar nos dois ao mesmo tempo
--   3. reconfirmar quem ja esta (ou trazer de volta quem foi removido)
--      nunca esbarra na propria vaga — e' a MESMA linha, nao duas
--   4. admin_buscar_participantes_sessao (20261001260000) so' traz
--      aprovado, e exclui quem ja esta confirmado em outra sessao do
--      mesmo tipo — o "Adicionar outro convidado" nao pode nem
--      OFERECER quem a adicao ia recusar depois
--   5. quarto "quadruplo", capacidade 4 (20261001230000)
-- =====================================================================

\set ON_ERROR_STOP off
set search_path = gestao, public;

begin;

-- ---------------------------------------------------------------------
-- CENARIO
-- ---------------------------------------------------------------------
insert into gestores (nome,email,empresa,cargo,segmento) values
  ('CIO Mesa Um','mesa-um@teste.invalido','Industria Mesa','CIO','Industria'),
  ('CIO Mesa Dois','mesa-dois@teste.invalido','Varejo Mesa','CIO','Varejo'),
  ('CIO Mesa Tres','mesa-tres@teste.invalido','Banco Mesa','CIO','Financeiro')
on conflict (email_norm) do nothing;

-- gestores.nome sai normalizado em maiusculas (padrao de cadastro,
-- 20260831170000) — o filtro aqui usa so' o e-mail, unico pra estes
-- gestores de teste, pra nao depender de caixa.
insert into participantes (evento_id,gestor_id,status,origem,aprovado_em)
select e.id, g.id, 'aprovado', 'manual', now()
from eventos e, gestores g
where e.slug='cerrado2027' and g.email like '%@teste.invalido'
on conflict do nothing;

select pa.id as p_um   from participantes pa join gestores g on g.id=pa.gestor_id where g.email='mesa-um@teste.invalido'   \gset
select pa.id as p_dois from participantes pa join gestores g on g.id=pa.gestor_id where g.email='mesa-dois@teste.invalido' \gset
select pa.id as p_tres from participantes pa join gestores g on g.id=pa.gestor_id where g.email='mesa-tres@teste.invalido' \gset

insert into patrocinadores (evento_id,cota_id,empresa,status)
select e.id,c.id,'Patro Mesa Alfa','ativo' from eventos e join cotas c on c.evento_id=e.id
 where e.slug='cerrado2027' order by c.ordem_prioridade limit 1;
insert into patrocinadores (evento_id,cota_id,empresa,status)
select e.id,c.id,'Patro Mesa Beta','ativo' from eventos e join cotas c on c.evento_id=e.id
 where e.slug='cerrado2027' order by c.ordem_prioridade limit 1;

select id as pa_id from patrocinadores where empresa='Patro Mesa Alfa' \gset
select id as pb_id from patrocinadores where empresa='Patro Mesa Beta' \gset
select id as ev    from eventos where slug='cerrado2027' \gset

-- mesa redonda da Alfa com 1 vaga so, mesa redonda da Beta tambem com 1,
-- e um JANTAR da Alfa (tipo diferente, pra provar que o mesmo CIO pode
-- estar numa mesa redonda E num jantar ao mesmo tempo)
insert into sessoes (evento_id,patrocinador_id,tipo,data,vagas,local) values
  (:'ev'::uuid, :'pa_id'::uuid, 'mesa_redonda', '2027-08-12', 1, 'Sala Mesa Alfa'),
  (:'ev'::uuid, :'pb_id'::uuid, 'mesa_redonda', '2027-08-12', 1, 'Sala Mesa Beta'),
  (:'ev'::uuid, :'pa_id'::uuid, 'jantar',       '2027-08-13', 2, 'Jantar Alfa');

select id as s_alfa   from sessoes where patrocinador_id=:'pa_id'::uuid and tipo='mesa_redonda' \gset
select id as s_beta   from sessoes where patrocinador_id=:'pb_id'::uuid and tipo='mesa_redonda' \gset
select id as s_jantar from sessoes where patrocinador_id=:'pa_id'::uuid and tipo='jantar'       \gset

set role authenticated;
set request.jwt.claims = '{"email":"gerardocarvalhogp@gmail.com","role":"authenticated"}';

\echo ''
\echo '#############################################'
\echo '# 1 · LIMITE DE VAGAS'
\echo '#############################################'
\echo '-- CIO Um confirmado na mesa da Alfa (1 de 1 vaga) — deve PASSAR'
select admin_adicionar_convidado_sessao(:'s_alfa'::uuid, :'p_um'::uuid) -> 'ok' as passou;

savepoint s_vaga;
\echo '-- CIO Dois tenta entrar na mesma mesa, ja cheia — deve FALHAR'
select admin_adicionar_convidado_sessao(:'s_alfa'::uuid, :'p_dois'::uuid);
rollback to s_vaga;

\echo '-- confere: so o CIO Um esta confirmado na mesa da Alfa'
select nome from admin_convidados_sessao(:'s_alfa'::uuid);

\echo ''
\echo '#############################################'
\echo '# 2 · RECONFIRMAR NAO ESBARRA NA PROPRIA VAGA'
\echo '#############################################'
\echo '-- adicionar o MESMO CIO Um de novo na mesma mesa (ja cheia com ele) — deve PASSAR'
select admin_adicionar_convidado_sessao(:'s_alfa'::uuid, :'p_um'::uuid) -> 'ok' as reconfirma_ok;

\echo ''
\echo '#############################################'
\echo '# 3 · MESMO TIPO NAO DUPLICA ENTRE PATROCINADORES'
\echo '#############################################'
savepoint s_dup;
\echo '-- CIO Um (ja confirmado na mesa redonda da Alfa) tenta entrar na mesa redonda da Beta — deve FALHAR'
select admin_adicionar_convidado_sessao(:'s_beta'::uuid, :'p_um'::uuid);
rollback to s_dup;

\echo '-- mas o MESMO CIO Um pode estar no JANTAR da Alfa — tipo diferente, deve PASSAR'
select admin_adicionar_convidado_sessao(:'s_jantar'::uuid, :'p_um'::uuid) -> 'ok' as jantar_ok;

\echo ''
\echo '#############################################'
\echo '# 4 · BUSCA PRA "ADICIONAR OUTRO CONVIDADO"'
\echo '#############################################'
\echo '-- na mesa da Beta (mesa_redonda, 1 vaga livre), buscar "Mesa" deve'
\echo '-- trazer CIO Dois e CIO Tres, mas NAO o CIO Um (ja confirmado numa'
\echo '-- mesa_redonda de outro patrocinador — o mesmo tipo, so que la):'
select nome from admin_buscar_participantes_sessao(:'s_beta'::uuid, 'Mesa') order by nome;

\echo '-- confirma o CIO Dois na mesa da Beta'
select admin_adicionar_convidado_sessao(:'s_beta'::uuid, :'p_dois'::uuid) -> 'ok' as beta_ok;

savepoint s_vaga2;
\echo '-- mesa da Beta tambem ja esta cheia: CIO Tres tenta entrar — deve FALHAR'
select admin_adicionar_convidado_sessao(:'s_beta'::uuid, :'p_tres'::uuid);
rollback to s_vaga2;

\echo ''
\echo '#############################################'
\echo '# 5 · REMOVER E READICIONAR (soft-delete nao prende a vaga)'
\echo '#############################################'
select admin_remover_convidado_sessao(:'s_jantar'::uuid, :'p_um'::uuid) -> 'ok' as removeu;
\echo '-- com o CIO Um fora do jantar, o mesmo CIO (que continua na mesa'
\echo '-- redonda da Alfa) pode ser readicionado no jantar de novo — deve PASSAR'
select admin_adicionar_convidado_sessao(:'s_jantar'::uuid, :'p_um'::uuid) -> 'ok' as readiciona_ok;

reset role;
reset request.jwt.claims;

\echo ''
\echo '#############################################'
\echo '# 6 · QUARTO QUADRUPLO (20261001230000)'
\echo '#############################################'
select _capacidade_quarto_patrocinador('quadruplo') as deve_ser_4;

set role authenticated;
set request.jwt.claims = '{"email":"gerardocarvalhogp@gmail.com","role":"authenticated"}';
select admin_criar_faixa_quartos('cerrado2027', 991, 992, 'quadruplo', 'Bloco Teste') -> 'criados' as criou_dois;

savepoint s_tipo_invalido;
\echo '-- tipo que nao existe deve FALHAR mesmo depois do quadruplo entrar na lista'
select admin_criar_faixa_quartos('cerrado2027', 993, 994, 'king_size', 'Bloco Teste');
rollback to s_tipo_invalido;
reset role;
reset request.jwt.claims;

-- authenticated nao le tabela direto (so RPC) — a conferencia crua
-- roda como postgres, depois do reset, mesmo padrao do teste 07
\echo '-- confere os dois quartos quadruplo criados, direto na tabela:'
select numero, tipo, capacidade from quartos where numero in ('991','992') order by numero;

rollback;

\echo ''
\echo '### transacao desfeita — o banco ficou como estava ###'
