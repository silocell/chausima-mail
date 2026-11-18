// Chausima Suite (built on CryptPad, AGPL-3.0). Settings on top of CryptPad's own.
(() => {
const factory = (AppConfig) => {
    AppConfig.disableCrowdfundingMessages = true;
    AppConfig.availableLanguages = ['en'];
    AppConfig.hostDescription = { default: 'Chausima Suite: documents, sheets, slides, forms and more, end-to-end encrypted. Sign in with your Chausima account.' };
    return AppConfig;
};
if (typeof(module) !== 'undefined' && module.exports) {
    module.exports = factory(require('../www/common/application_config_internal.js'));
} else if ((typeof(define) !== 'undefined' && define !== null) && (define.amd !== null)) {
    define(['/common/application_config_internal.js'], factory);
}
})();
