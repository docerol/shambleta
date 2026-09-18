// Shambleta — ponte de rewarded ads (SOM-IDLE Fase E, MONETIZATION §2.5).
//
// O client Godot (sources/ads/AdProvider.gd, provider "portal") procura
// `window.ShamletaAds` com dois métodos:
//
//   ShambletaAds.ad_ready(placement) -> bool
//       "há um rewarded disponível para este placement?" (4 placements:
//       "afk2x", "chest", "reroll", "bosskey").
//   ShambletaAds.show_rewarded(placement, done_callback)
//       exibe o rewarded; chama done_callback(true) SE o anúncio foi assistido
//       até o fim, done_callback(false) se pulado/fechado antes. O Godot passa
//       um Callable como done_callback (JavaScriptBridge invoca de volta).
//
// Decisão do dono (2026-09-18): CRAZYGAMES. Trocar o corpo das duas funções
// abaixo pelo SDK real quando a conta do portal existir; o jogo não muda.
// Seleção via env SHAMBLETA_AD_PROVIDER ("stub" = sem SDK, "portal" = usa esta
// ponte). Sem esta ponte carregada, o client cai para o stub — o servidor
// continua fail-closed (formato + dia; token adulterado nunca credita) e os
// caps (6/dia, 1 baú/dia, 2 chaves/dia) valem nos dois caminhos.
//
// Até a conta existir, este arquivo é o MODO DE TESTE: simula um anúncio de
// 2s e confirma conclusão, para validar o fluxo ponta-a-ponta.
//
// Uso (operador): incluir o SDK do portal + este arquivo no index servido,
// antes do boot do Godot. Ex. CrazyGames v3:
//   <script src="https://sdk.crazygames.com/crazygames-sdk-v3.js"></script>
//   <script src="/ads_bridge.js"></script>
(function () {
  "use strict";

  // Modo de teste (default): finge um anúncio de 2s sempre concluído.
  // Com portal real, substitua TEST_MODE por false e preencha os dois
  // métodos com as chamadas do SDK (ver exemplos comentados abaixo).
  var TEST_MODE = true;
  var TEST_SECONDS = 2;

  function crazyReal_show(placement, done) {
    // Exemplo CrazyGames v3 (descomentar com o SDK carregado):
    // window.CrazyGames.SDK.ad.requestAd("rewarded", {
    //   adStarted: function () {},
    //   adFinished: function () { done(true); },
    //   adError: function () { done(false); },
    // });
    done(false);
  }

  window.ShambletaAds = {
    ad_ready: function (placement) {
      if (TEST_MODE) { return true; }
      // Portal real: return window.CrazyGames ... disponibilidade;
      return false;
    },
    show_rewarded: function (placement, done) {
      if (TEST_MODE) {
        setTimeout(function () { done(true); }, TEST_SECONDS * 1000);
        return;
      }
      crazyReal_show(placement, done);
    },
  };
})();
