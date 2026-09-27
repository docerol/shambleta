# Protocolo de avaliação cega — Shambleta

Este arquivo define o prompt dado a um agente julgador. Ele existe para que a
nota por categoria seja produzida **sem contaminação** pelo resultado anterior.

## Regras do juiz

1. O juiz NÃO lê nem recebe: `AUDITORIA_2026-09-27.md`, `AUDITORIA_INDEPENDENTE_2026-09-24.md`,
   `ROADMAP_COMERCIAL.md`, notas antigas, resumos de sessões anteriores, este protocolo preenchido.
   Nada sobre "o que foi corrigido" — o juiz avalia o estado do repo como se o visse pela primeira vez.
2. Avalia as 20 categorias (0–10, uma casa decimal): Core Gameplay, Core Loop, Meta Game,
   Game Design, Retenção, Economia, Monetização, Marketplace, Segurança, Arquitetura,
   Performance, Escalabilidade, UX/UI, Social, Live Ops, Analytics, Testes, DevOps,
   Documentação, Código.
3. **Nota > 9 exige prova executável**: para cada categoria acima de 9, o juiz deve citar
   arquivo:linha e, onde cabe, resultado de teste realmente rodado. Sem prova, a nota não passa de 9.
4. Regra anti-invenção: problema não confirmado no código é marcado `HIPÓTESE` e **não** derruba nota.
5. O juiz entrega, por categoria: nota, 3 evidências concretas e a **lacuna específica** que
   separa a nota de >9 (se for o caso).
6. Dois juízes independentes por rodada; a nota final da categoria é a **mínima** entre os dois.

## Rodada 1 — lançada em 2026-09-27

Juízes: `blind-judge-a`, `blind-judge-b` (agentes novos, posse somente de leitura).
