// Chausima Suite wording: CryptPad's English text with the product names changed. Admin-only text and web links are left alone.
define(['/common/translations/messages.js'], function (M) {
    function swap(v) {
        return v.replace(/(^|[^\w\/.@-])CryptPad\b(?![\w.-]*\.(?:org|fr|net|com)\b)/g, '$1Chausima Suite')
                .replace(/\bCryptDrive\b/g, 'Chausima Drive');
    }
    Object.keys(M).forEach(function (k) {
        if (/^admin_/.test(k)) { return; }
        var v = M[k];
        if (typeof v === 'string') { M[k] = swap(v); }
        else if (v && typeof v === 'object' && !Array.isArray(v)) {   // grouped names, like the app titles
            Object.keys(v).forEach(function (j) { if (typeof v[j] === 'string') { v[j] = swap(v[j]); } });
        }
    });
    M.main_title = 'Chausima Suite';
    M.main_catch_phrase = 'Documents, sheets, slides, forms and more. End-to-end encrypted, with your Chausima account.';
    M.info_sourceFlavour = '<a>Source code</a>';
    M.user_about = 'About Chausima Suite';
    M.docs_link = 'About Chausima';
    return M;
});
