// "AI writing helper" in the Chausima Suite user menu. Documents are end-to-end encrypted, so the helper opens
// beside them: paste text in, copy the result back. https://hwlai.civilinitiatives.org/write.html
define(['/common/hyperscript.js', '/common/common-icons.js'], function (h, Icons) {
    return function () {
        var HELPER = 'https://hwlai.civilinitiatives.org/write.html';
        return {
            USERMENU_ITEM: [{
                getItem: function (Common) {
                    var icon; try { icon = Icons.get('edit'); } catch (e) {}
                    return {
                        tag: 'a',
                        attributes: { 'class': 'cp-toolbar-chzai' },
                        content: h('span', [icon, ' AI writing helper']),
                        action: function () {
                            var w = null;
                            try { w = window.open(HELPER, 'chzai', 'popup,width=460,height=780'); } catch (e) {}
                            if (!w && Common.openUnsafeURL) { Common.openUnsafeURL(HELPER); }
                        }
                    };
                }
            }]
        };
    };
});
