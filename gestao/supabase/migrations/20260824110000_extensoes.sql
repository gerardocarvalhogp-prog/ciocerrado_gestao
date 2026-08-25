-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Extensoes de que o schema `gestao` depende.
--
-- Vem antes do baseline porque o dump nao as traz: no projeto hospedado
-- elas ja existiam (o schema `public`, do sistema de massagem, as
-- instalou primeiro).
--
--   pgcrypto   gen_random_uuid(), default de quase toda chave primaria
--   unaccent   admin_salvar_evento chama unaccent('unaccent', ...) para
--              montar o slug a partir do nome
--
-- Sem `unaccent` o banco sobe e so quebra na primeira vez que alguem
-- salva um evento — erro em tempo de execucao, nao de migration.
-- =====================================================================

create extension if not exists "pgcrypto";
create extension if not exists "unaccent";
