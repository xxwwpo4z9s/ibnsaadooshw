/*************************
common.js

common.js -> module.js 연동처리
*************************/
(function($) {
    /*setup*/
    var _setup = function() {
        var beepOne = $("#snd_over")[0];
        //        $('a').bind('mouseenter', function (event) {
        //            beepOne.pause();
        //            beepOne.play();
        //        });
    };
    $.COM = {};
    $.COM = {
        setup: function() {
            $.COM._logo = $('header .logo a');
            $.COM._new = $('article.new');
            $.COM._main = $('article.main');
            $.COM._dash = $('section.da');
            $.COM._account = $('section.ac');
            $.COM._blockInfo = $('section.bl');
            $.COM._config = $('section.co');
            $.COM._wallet = $('ul.account');
            $.COM._walletAddBtn = $('nav .wallet ');
            $.COM._popup = $('article.popup');
            $.COM._toggle = $.COM._account.find('.toggle dl');
            $.COM._receiveBos = '';
            /*  init  ************************/
            $.COM._accountAddress = '';
            $.COM._passPhrase = [];
            $.COM.setLoginMode("start");
            //  $.COM.setLoginMode("start");
        },
        /*
            Login
        */
        createPhrase: function() {
            $.FUNC.creatSeed(function(data) {
                var _word = data.passphrase.split(" ");
                var _ul = $.COM._new.find('> section.phrase ul.list');
                $.COM._passPhrase = [];
                _ul.children().remove();
                var _ele = '';
                for (var i in _word) {
                    _ele += '<li><span>' + _word[i] + '</span></li>';
                    $.COM._passPhrase.push(_word[i]);
                }
                _ul.append(_ele);
            });
        },
        writePhrase: function() {
            var _ele = '';
            var _ul = $.COM._new.find('> section.check ul.write');
            _ul.children().remove();
            for (var i in $.COM._passPhrase) {
                _ele += '<li><input type="text" data-val=' + $.COM._passPhrase[i] + '></li>';
            }
            _ul.append(_ele);
        },
        /*
        login / New Accout / passPhrase
         */
        setLoginMode: function(mode) {
            $.COM._new.find('> section').removeClass('on');
            var _target = $.COM._new.find('section.' + mode).addClass('on');
            if (mode == "start") {
                $.COM._new.show();
                $.COM._main.hide();
            } else if (mode == "create") {
                var _time = 1000;
                var _st = setTimeout(function() {
                    clearTimeout(_st);
                    _time = null;
                    $.COM.setLoginMode('phrase');
                }, _time);
            } else if (mode == "phrase") {
                $.COM.createPhrase();
                //$.COM._new.find('section.' + mode).fadeIn();
            } else if (mode == "check") {
                $.COM.writePhrase();
            } else if (mode == "loading") {
                var _time = 1000;
                var _st = setTimeout(function() {
                    clearTimeout(_st);
                    _time = null;
                    $.COM._new.hide();
                    $.COM._main.show();
                    $.COM.setLayout("dash");
                }, _time);
            }
        },
        /*
            Dashboard / Account / Block Mode
        */
        setLayout: function(mode) {
            $.COM._main.find('> section').removeClass('on');
            if (mode == "dash") {
                $.COM._dash.addClass('on');
                //--대쉬보드
                var _list = $.COM._dash.find('nav > section'); //account계정리스트
                if (_list.length == 0) {
                    $.FUNC.createCount(function(data) {
                        $.COM._accountAddress = data.accountAddress;
                        $.COM.addCount($.COM._accountAddress);
                        //-------------------------------------------------------
                        $.FUNC.getAccount(function(data) {
                            $.COM._dash.find('.address').text(data.accountAddress);
                            $.COM._dash.find('.coin').text(data.accountBalance);
                        }, $.COM._accountAddress);
                    });
                }

            } else if (mode == "account") {
                $.COM._account.addClass('on');
                var _address = '';
                $.FUNC.getAccount(function(data) {
                    //acount
                    $.COM._account.find('.address em').text(data.accountAddress);
                    $.COM._account.find('.account span').text(data.accountBalance);
                    $.COM._account.find('.available span').text(data.availableBalance);
                    $.COM._account.find('.pending span').text(data.pendingBalance);
                    //전역변수
                    $.COM._accountAddress = data.accountAddress;
                    //freezingStatus
                    if (Boolean(data.freezingStatus)) {
                        $('nav.freezing-cont').removeClass('freezing');
                    } else {
                        $('nav.freezing-cont').addClass('freezing');
                    }
                }, $.COM._accountAddress);
            } else if (mode == "block") {
                $.COM._blockInfo.addClass('on');
            } else if (mode == "config") {
                $.COM._config.addClass('on');
            }
        },
        /*
            Set Layer Popup
        */
        setPopup: function(mode) {
            if (mode == "close") {
                $.COM._popup.removeClass('on');
                $.COM._popup.find('section.layer').hide();
            } else {
                $.COM._popup.addClass('on');
                $(mode).fadeIn('fast');
            }
        },
        /*
         */
        setToggleMenu: function(mode) {
            if (mode == "init") {
                $.COM._toggle.removeClass('on');
            } else if (mode == "receive") {
                $.COM._toggle.eq(0).addClass('on').siblings().removeClass('on');
            } else if (mode == "send") {
                $.COM._toggle.eq(1).addClass('on').siblings().removeClass('on');
            } else if (mode == "transaction") {
                $.COM._toggle.eq(2).addClass('on').siblings().removeClass('on');
                //myTransaction
                $.FUNC.getAccountTransaction(function(data) {
                    var _ele = '';
                    for (var i = 0; i < data.length; i++) {
                        _ele += '<tr><td>' + data[i].timestamp + '</td><td>' + data[i].amount + '</td><td>' + data[i].fee + '</td> <td>' + data[i].accountAddress + '<em></em></td></tr>';
                    }
                    $('.my-transaction table tbody').children().remove();
                    $('.my-transaction table tbody').append(_ele)
                }, $.COM._accountAddress);
            }
        },
        /*
        receiveBos
        websocket.js 에서 받은 return 값
        */
        receiveBos: function(param) {
            if (param.isTrusted) { //유효성체크
                //{TEXT} 형태로 받은것을 REG 및 object로 치환
                var _re = /[{"}]/gi,
                    _data = {};
                var _ary = param.data.replace(_re, '').split(',');
                for (var i = 0; i < _ary.length; i++) {
                    var filter = _ary[i].replace(_re, '').split(":");
                    _data[filter[0]] = filter[1];
                };
                $.COM._receiveBos = _data;
                var _receiveAddrs = _data.receiverAccountAddress;
                var _div = $.COM._dash.find('div.address').filter(function(index) {
                    return $(this).text() == _receiveAddrs;
                });
                $.COM.addReceiveBos(_data);
                //$.COM.setLayout("account");
                //$.COM.setToggleMenu("receive");
                $.COM._dash.find('section').find('.receive').after('<i class="receive">2</i>');
                $.COM._account.find('.toggle dl:eq(0) dt span').append('<i class="receive">2</i>');
            }
        },
        /*
        add Receive BOS
        */
        addReceiveBos: function(data) {
            var _ele = '<tr><td><i><img src="./images/ac_ico_receive_arrow.png"></i>Receiving..</td> <td>' + data.amount + '<em>BOS</em></td> <td>Show Detail</td></tr>';
            $.COM._account.find('dl.receive table tbody').append(_ele);
        },
        /**/
        addCount: function(address) {
            var _ele = '<section class="clfix"><div class="pay"><a href="#"><div class="address">' + address + '</div><p class="coin">0<em>BOS</em></p></a></div><ul class="ctl clfix"> <li> <a href="#" class="receive"><img src="/images/ico_receive.png"></a> </li> <li> <a href="#" class="send"><img src="/images/ico_send.png"></a> </li> <li class="freez"> <a href="#"><img src="/images/ico_freezing.png"></a> </li> </ul> </section>';
            $('.da nav').append(_ele);
        },
        end: function() {}
    }
    /*
    Binding
    */
    var _bind = function() {
        /*테스트코드*/
        /*login passPhrase*/
        $.COM._new.on('click', 'a.link', function(event) {
            var _cls = $(this).attr('data-val');
            var _section = $.COM._new.find('>section');
            $.COM.setLoginMode(_cls);
        });
        /*대쉬보드 이동*/
        $.COM._main.on('click', 'header .close', function(event) {
            $.COM.setLayout("dash");
        });
        /*Configuration 이동*/
        $.COM._main.on('click', 'a.config', function(event) {
            $.COM.setLayout("config");
        });
        /*계정추가 add_new_account*/
        $.COM._wallet.on('click', '.add', function(event) {
            $.FUNC.createCount(function(data) {
                $.COM._accountAddress = data.accountAddress;
                $.COM.addCount($.COM._accountAddress);
            });
        });
        /*Block Info*/
        $.COM._dash.on('click', '.info-wrap a', function(event) {
            $.COM.setLayout("block");
        });
        /*계정자세히보기*/
        $.COM._dash.on('click', '.pay>a', function(event) {
            $.COM.setLayout("account");
            $.COM.setToggleMenu("init");
            //-
        });
        /*Receive*/
        $.COM._dash.on('click', '.ctl .receive', function(event) {
            $.COM.setLayout("account");
            $.COM.setToggleMenu("receive");
        });
        /*Send*/
        $.COM._dash.on('click', '.ctl .send', function(event) {
            $.COM.setLayout("account");
            $.COM.setToggleMenu("send");
        });
        /*Toggle Freezing*/
        $.COM._dash.on('click', '.ctl .freez', function(event) {
            $.COM.setLayout("account");
            $.COM.setPopup('section.un-freezing');
        });
        /*Set Freezing*/
        $.COM._account.on('click', 'button.freezing', function(event) {
            $.COM.setPopup('section.freezing');
        });
        /*Send BOS*/
        $.COM._account.on('click', 'ul.form button.send', function(event) {
            $.COM.setPopup('section.send-bos');
        });
        /*Send BOS Cancel*/
        $.COM._account.on('click', 'ul.form button.cancel', function(event) {
            $.COM.setPopup('section.send-bos-cancel');
        });
        /*BOS Receive,Send,Transaction,Backup*/
        $.COM._account.on('click', '.toggle dl dt', function(event) {
            var _dl = $(this).parents('dl');
            var _idx = _dl.index();
            var _param = ["receive", "send", "transaction", "backup"];
            if (_dl.hasClass('on')) {
                _dl.removeClass('on');
            } else {
                $.COM.setToggleMenu(_param[_idx]);
            }

            //		$(this).parents('dl').toggleClass('on');
        });
        /*Configuration Toggle*/
        $.COM._config.on('click', '.toggle dl dt', function(event) {
            $(this).parents('dl').toggleClass('on');
        });
        /*팝업닫기*/
        $.COM._popup.on('click', '.layer footer a', function(event) {
            $.COM.setPopup('close');
        });
        /*프리징하기*/
        $.COM._popup.on('click', '.freezing footer a', function(event) {
            $.COM.setPopup('close');
            //calc
            $('.freezing-cont').addClass('freezing');
        });
        /*언프리징하기*/
        $.COM._popup.on('click', '.un-freezing footer a', function(event) {
            $.COM.setPopup('close');
            //calc
            $('.freezing-cont').removeClass('freezing');
        });
        /*BOS보내기*/
        $.COM._popup.on('click', '.send-bos footer a', function(event) {
            $.COM.setPopup('section.send-bos-ok');
            //
            var _params = '';
            _params = $.COM._account.find('.account .address').text();
            _params += "/" + $('ul.form input.receiver').val();
            _params += "/" + $('ul.form input.amount').val();
            _params += "/" + $('ul.form input.memo').val();
            $.FUNC.sendBos(function(data) {
                console.log(data);
            }, _params);
        });
    }

    /*ADD_ACCOUNT
     */
    $(document).ready(function() {
        _setup();

        $.COM.setup();
        _bind();
    });
})($);
