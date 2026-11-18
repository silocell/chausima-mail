// Chausima Suite wording: CryptPad's English text with the product name changed. Admin-only text and web links are left alone.
define(['/common/translations/messages.js'], function (M) {
    Object.keys(M).forEach(function (k) {
        if (typeof M[k] !== 'string' || /^admin_/.test(k)) { return; }
        M[k] = M[k].replace(/(^|[^\w\/.@-])CryptPad\b(?![\w.-]*\.(?:org|fr|net|com)\b)/g, '$1Chausima Suite');
    });
    M.main_title = 'Chausima Suite';
    M.main_catch_phrase = 'Documents, sheets, slides, forms and more. End-to-end encrypted, with your Chausima account.';
    M.info_sourceFlavour = '<a>Source code</a> for Chausima Suite (built on CryptPad, AGPL-3.0)';
    M.user_about = 'About Chausima Suite';
    M.docs_link = 'About Chausima';
    return M;
});
