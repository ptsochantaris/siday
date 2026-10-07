// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// From AtariAudio by Arnaud Carré, used under the MIT licence (see THIRD-PARTY.md).

/// The forty drum sounds of the oldest kind of YM file (YM2), which names its drums by number and
/// expects the player to have them: samples of sixteen levels, to be played on the sound chip's
/// volume register.
enum YM2Drums {
    /// Where each drum starts among the samples, and how many samples long it is.
    static let offsets: [Int] = [
        0, 631, 1262, 1752, 2242, 2941, 3446, 4173, 4653, 6761,
        10992, 11370, 12897, 13155, 13413, 13864, 15659, 15930, 16563, 17942,
        18089, 18228, 18313, 18463, 18970, 19200, 19320, 19591, 19884, 20275,
        20666, 21057, 21464, 21871, 22278, 22595, 23002, 23313, 23772, 24101,
    ]
    static let lengths: [Int] = [
        631, 631, 490, 490, 699, 505, 727, 480, 2108, 4231,
        378, 1527, 258, 258, 451, 1795, 271, 633, 1379, 147,
        139, 85, 150, 507, 230, 120, 271, 293, 391, 391,
        391, 407, 407, 407, 317, 407, 311, 459, 329, 656,
    ]

    /// The samples, 24,757 of them, two to a byte with the first in the top half, in base64.
    static let packed: StaticString = """
7e3d3d7PDcvN3dzQvN7///7bqXAAB9/////+2wAAAAAJ3//////toAAAAAAACt////////7ccAAAAAAAAAzf//////////2wAAAAAAAAAJzv///////////t
xwAAAAAAAAAAe83v////////////7cuQAAAAAAAAAACc3u////////////7coAAAAAAAAAAAnN3u////////////7u3dzLqpl5mZq8zMzMzMzMzMzMzM3d3d
3e7u7//////+7u7t3d3cy7qXAAAAAAAAeavM3d3u//////////////7t3Ny6lwAAAAAAAAAAeavM3e7u///////////////u7t3cy6qZcAAAAHd5mqu8zM3d
3d3u7u7u/u7u7u7u7t3d3d3d3dzMu7u7u7zMzN3d3d3d3d3dzMzMzM3d3d3d3d3d3d3d7N3N3d3dzN3d3u7dzMzMzM3e7u7u3czMzMzMzd7u7u7t3MzMzMzM
zM3u7u7u7u7d3MzMzMzMzMzd3u7u7u7u7u3czMzMzMzMzMzd3u7u7u7u7u7d3czMzMzMzMzMzM3d3u7u7u7u7u7u3d3MzMzMzMzMzMzM3d3u7u7u7u7u7u7d
3MzMzMzMzMzMzN3d3u7u7u7u7u7u3d3d3dzMzMzMzM3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3czMzMzMzMzMzMzN3d3d3d7u7u7u7u7u7t3d3d3c
zMzMzMzMzMzMzMzN3d3d3d3u7u7u7u7u7d3d3d3d3czMzMzMzMzMzMzM3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3MzMzMzd3d3d3d3d3d3d3d3d3d3d3d3d
3d7coH0L/////rAAAAAA/////////8eQAAAAAAAAnv////////+wcAAAAAAAAH3u////////wKAAAAAADdzP6//f///////f6wAAAAAAx6///////+79/n6Q
cAAAcNfP3////+3u1+zg/OmtqQDADcDf7//////e7q4NqQqpfcrP3f/u7f/e397s7Au6rHnQ3N387//e/s7uzbrJx7l6u8297v///+7vzNvJ27rdz9/u3d3t
/d/f7e7d7drdvNut3t3O7e3t/tr+3Lydd93d3d3c297Ozt3d7e3s3c287N3N3d7u/f/uzt3c3c7Nzdzd3svt3d3d3d3Mzczu7u7tzMzMzMze7u7u7u7t3MzM
zMzMzMzN7u7u7u7u7szMzMzMzMzMzd3u7u7u7u7czMzMzMzN3d3c7t7u7u7u7t7czMzMzMzczt3u7u7u3e3tzczMzMzM3N7e7u7u3d3c3dzd3M3MzNzN3N7e
7u7u7d3dzc3MzMzN3N3d3d3d3t3e3d3dzMzNzNzd3d3e7t3d3d3dzNzczMzM3c3d3e7t3d3d3NzczN3d3d3d3d3d3d7d3d3d3N3d3M3d3d3d3d3t3N3dzc3M
3d3d3d3c3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3N3d3d3d3d3d354K/v3+3frZwPDwDMDaDQAMu+7//////////9+6AAAAAAAAAAAAAJp/////
///////////////nAAAAAAAAAAAAAAAAAAAAAM/////////////////////////+2gAAAAAAAAAAAAAAAAAAAAAAAAAAAAvf////////////////////////
/////+uQAAAAAAAAAAAAAAAAAAAAAAAAAACt3//////////////////////////u3MupBwAAAAAAAAAAAAAAAAAAAAAAAHeczN3d7u7v////////////7+7u
7u7t3dzMzMy7u5qXmXd3d5l3mauqu8vMzN3d3d3e7u7u7u7u7u7u7+7u7//////////u7u7u3d3d3My7u6qqmZeXeXl3l5maqrq7u8zMzc3d3d3u7u7u7u7u
7u7u7t3d3d3dzMzMzLu7uru7u7u7zMzMzc3d3d3d3d27yZ3f7+7t3MCQcAAAve///9/u////3JAAAAAAAAvf///////////+0AAAAAeXmXB3mq7d3dywAAnO
7///////3e7f//7t3Nvd3dzstwoNdwkLnc3uzsqgCXeQCXm9///////////////9sAAAAAAAAAkHeXq8zd3d3v/////////////t2rAAAAAAAAAAAAnHzN7u
/v39/f7//////////////tugAAAJB3AHAAAAAACZu9ze7///////7+7+7evHe3AABwAJrM7t3uzt3NzMzc3e3u7v/////////u3ty6AAAAAAoHp5l3BwcKe7
zN3u7u7u/t3d3d3d3drezf0L7u7Hve/8AM/92Q78necN//AMwAD///0AAAf/////8AAAAK7//+cADd3/////0AAAAAz///////3v2gAAAAAADe/////////a
oAAAAAAKrOzv///////7CgAAAAAK+gD//d7//////QAAAAwAzAu62s/Xzd7//v//nP8ACgCwCv9w/Qf+wM///v/9v/AMwAAAr7Cd4A3wD//f/8///9AP8A2g
zQCf8Av/2u//3//Q76CvoA7sAP0A/wAP9w/////8C/8AD/cN/gzwAKDXf/97//cO/wCv+Q787pz9AP4Afu7//f/d/QD/0K/wD9AL6QDPx//9z//tuf9wAN7A
C9rsCf8Ar/2c/+/Qn93Avs3/AP/XDPoP9w/+DP+c/Qz+AP//oO8H+w3tAP/Qr/AP8H/3D/3/cP8A7gr+AO/Qz9DuzgD/0N/n3McNoA77AP/73t//DP/9ff/Q
3pfvsA/wDf8H/6Dvut3d3dr39/fu788P3vn9n67w+68P0P9/4O4N53/dDvmt2t6r7qv+C+63v6Dfx++wn/oH7/0L/9nP65z//ADv/Jfu397ADP/9oH3/3ACc
//6gDP//sACe///JAADf///goAm97v/e7+yaCcrP//3OugAA3u///+3M2wAAnP/////t3ckAB5Cb3v///97t3LkAAAe83d7v///+/v7XAMAACs3M3d7d3u7/
/t3d7v/9q8zJAJAACt793e7f///tzc27zMzdzN3/2gmszNzd3d3u7d7u7t3czMzN3d3d7dyqAAC93dzd3e7v7u3d7e7u3u7u/93d3d3tqbzf3czN3f3KCr3u
3c3d3v3LkMze793d3d3d3+y6cLzd3v3d3d3d3d/sype83t7u3d3d3d3d/8uZC73d393d3d3d3e3sp5e83d7+7d3d3d3ezsqZms3e/d3d3d3e7MoLvN7d3N3d
3uzKDM3e3dzd3d7sygu93t3c3d3e7MsMzd7d3N3d3uzLDM3f3c3d3e/cp8zd/dzd3d7ty3zN3u3c3d3e7ct8zd7t3M3d3u3KC83e7dzd3d7ty3vN3f3d3d3d
7ty5rM3f3d3d3d3+zKDM3d/d3N3d3e7Mqazd3u3d3d3d3+y5DM3d/d3d3d3e7Mqbzd3t3d3d3d3u3Lp7zd3f3d3d3d3d/sqpnN3e7d3d3d3d3/y6l8zd3u3d
3d3d3d7cuZnM3d793d3d3d3e7LqXvN3e7t3d3d3d3d/suZoMzd3u/d3d3d3d3d/sqZoM3d7u/u3d3d3d3d/ruZkLzd7u/e3d3d3d3d/NuZoN3d7u/O3d3d3d
3d7dmpkMzd7u/t7d3d3d3d7tp6cJ7O7u/87d3d3d3d79wKcNzd7u/u3d3d3d3d3t26mZrN3u7v7t3d3d3dzd3eupqgzd7u7v7t3d3dzMzM39y6mqfN3u7u/u
3d3d3MzM3f3Lqqp93e7u7v7t3czMzMzMze7Lqrt93u7u7+7t3czMzMzMzd+bqrsN3u7u7u7t3MzMzMzMzd3e7LurzJ3e7u7u7t3MzMzMzMzM3d7szKvMDd7u
7u7v7czMzMzMzM3d3658q7x93u7u7u/d3NzMzMzMzN3f7cqqvMne7u7u7u/dzLu7u8zMzN3d3t/My8zMvd7u7u7u/dzMu7u7zMzN3d3t/cy8zMDt7u7u7u/O
vLu7u7zMzN3d3v3sq8zMnP3+7u7u/dzMu7u7zMzN3d3d/fzLvMzH3e7u7u7u/dzLu7u7zMzd3d3d/erLzMzH7e7u7u7u+9rLu7u7zMzN3d3e/e2rzMzH7f7u
7u7u7ty6qqq7vMzN3d3d3d7d3MvMzN2d7u7u7u7d68yqqqqrvMzd3d3d3e/O2tvMzdy/3+/u7u7d7cuqmaqqvMzd3d3d3u3d7d7Mu8zN3c7u//7u7t3d3Mp3
eZqrvM3d3d7u7u7u777ayszN3dru7u7u7t3dzOqnd3mqu8zd3d7u7u7u7t793cu8zM3d3O7u7u7t3dzM4LCXmaq8zN3d7u7u7u7u3f3erLzMzd3dru7u7u3d
3My7vZl3mavMzd3d7u7u7u7u3d3d373cvLzM3d3dv97u7t3d3My7vcepmrzM3d3e7u7u7u7u3d3d3d3f3drLvMzd3d3d3e7u3d3czMu7u72qusvM3d3u7u7u
7u7u7d3d3d3d3d7MzMu7zMzd3d2u7u7t3d3czMzMzOq7vMzd3d7u7u7u7u7t3d3d3d3d3d3d3d3Mzc3MzMzMzLu7zMzN3e7u//////7u7d3Mu7u6mpqam7u8
zN3d3d3d3u//////////////////////7u3boAAAAAAAAAAAAAAAd5eXAAAAAAB5m6u8zMzd3e7u7u///////////////////u3czLqqu8zMzd3d7u7u/v7u
3Mu6qqvMzMu7u8zN3d7u7u3Ly8vN3d7d3d3d3d7u7u7cp3B5rM3d3dzM3d7u7//+3HcHmbzd3d3LvN3e7///7Ldweb3d7u3czM3e7////sp3B3vN3d3cu7zN
7u///stwAJvd3u3buZrN7v///+qQAAve7v7cqQe83v////6rAADM3//d2gCbve/////8xwAJzO/u7sl3es3v////3MAAB53u7+3LoHrN7////92gAACd3v/u
3JeZze7///7tAAAArN7v/uy7m83v////y5AAB6zd7u7dzN3e//7+vZCQCqvN3u3dzd3u//7+raCnC6zNze3dzd3u7//vzdCaCaq93e3e3d3e7//f6+l8B6ms
3O3e3e3e7v/u+ex8kKmr293e3e3e7v/9/c6bsJmZzM3d7d3d7u/+7766yXqZrL3d7d7d3u//793pypmpnLzc3d3d3u7//vztrKmamsvdzd3d3e7u/u/OvLqa
qbytzd3d3d7v7+/s68yqqpvL3N3d3d3t/v7vzsvJqqqsvd3d3d3e3u79/d68yrq6vL3N3d3d3t7u/u7OzMu6u6y83N3d3d7e7u7t7d3My6vKzc3c3c3d3d3u
7u3t3cvKu8zNzd3d3d3d3d7e7t7c3Ly7zMzdzd3d3d3e3d3t7d3d3MzMzM3d3d3d3d3d3d3d3d3d3d3MzMzMzc3c3d3d3dzt7d7e3t3d3Nzc3c3Mzczc3d3d
7d3d3d3d3d3d3czMzM3Nzc3d3d3d3d3d3d3N3d3d3c3N3Nzdzdzc3N3N3d3d3d3d3d3d3d3N3dzd3N3c3d3d3d3dzd3d3N3dzc3d3d3d3dzdzd3d3d3dzd3c
3d3d3dzd3c3d3d3dzNzc3d3c3N3M3d3d3d3d3d3d3d3d3d3d3d7u7u7u3e7e7t3d3d3d3MzLvLu8u7vMzM3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d
3d3d3d3d3d3d3d3d3d3d3d3MzczM3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3M3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3M3d3d
3d3d3d3d3d3d3d7t3dzMzd3d3d3d3d3d3d3d3u7u3czMzd3d3d3d3d3d3d3d3u7dy6qrzM3d3d3Mu83d3d3e7u7dyqq83d3d3dy6mb3e7d3e7u3Kd5vd3d3d
3cuXm93u7u3u/+23Cc3u7t3d3Kd5ze7u3e7v/scAfN7u3d3cqXvN7u3d3u//7AAAzv/u3cuXm97u3M3e7//+wAAN//7cy5AL3/7KvO7u7//pAAz//t3cAAz/
/Zet3e7////AAJ7//tyQB9/+yXvN3u7u7/+gAN/+7dwADf/rmrzN7u3e///AAM7//toAnf/sqZvN7tze///8AA3//u0ADP/tyZCt79ze/u//0ADe///QAN7/
/pAK7t3dze7+//AA3u7/0Afe7/6QC97u66zv7v/9AAre/+oAmt//3JAL3t3Mze7u//4ACc3/7JcA3//tsAve7uvN3u///9AHfO/+2wAN7v/rAJfO7t3c3u7/
/8BwDe/u7Hmb3v7usJet7t7s3d7v//yaAM3u/tywe83v7dqXnN7u7u3e7v/tzAC6zu7u27p8ze7t25ur3e7u3t3u7tzHm63t7t3MzMzd3d3czM3d3e7u7u7t
zKe6zd3t3d3czMzd3d3dzdzd3u7u7u3Nurmszd3u7d3Mu8zN3d3d3d3u7u///92ZAAeb3e7u7u3cyqmbvN3e3u3e7///3cq5mpe7ze7+7t3cu6rLvc3d3e7u
//793by3d3rM3d7u7t3cy7y7zM3N3u7u7u7+7c2ZmavM3d7u7u3d3Mu6u8zN3u7u7u7u7cy7q6u8zd3e7d3d3NzLu8zd3d3e7u7+7cy7vLzLzN3d7u7d3d3M
zMzM3d3d3u7u7e3czMu8zN3d3d7u3d3Nzd3dzMzN3d3d3d3d3d3d3MzM3d3NzN3d3d3d3d3d3M3d3d3d3d3d3d3d3d3MzM3d3d3d3d3d3d3d3d3N3d3d3d3M
zd3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3M3d3d3d3d3d3d3d3d3d3d3d3d3d3d3N3d3d3d3d3d3d3d3d3d3dzM3d3d3d3d3d3d3d3d3d3d3d3d3d
3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3Nzd3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d
3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3Nvc3d3d3d3d3c3d3d3d3d3d3d3d3d3d3d3d3d3c3c3c3d3d3d3d3d
3L3O3s7erN3e3e3d3c3czd3czd3d3d3d3d3d3d3N3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3N3d3d3d3d3d3c3d3d3dzd3d3d3d3d3d3d3d3d3d3d3d3d3d3d
3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d
3d3d3d3d3e///t/w/P9/DQcAAAAAAAAAAACXzO7////////////////exwAAAAAAAAAAAAAAAAAAAAAAes3e/////////////////////////+3cuQAAAAAA
AAAAAAAAAAAAAAAJzc3u7//////////////////////+7t3NzMqZAAAAAAAAAABwe3rc3t7t3d3u7e7u3e7u/v//7t3d3d3Mm7eQp5AHAAAHepqrrMzdzd3u
7e7e7u7u7u/u/u7t3d3d7e7f/8+97//////w6wBwrf///+///9//////7cAHAHAAALDuv//v7t7u7sygAAAAAAAAANnp3f7e7d/O7d3QAAAAB3AJunzZ/f7/
/////93tu8zbzcp67e3v////////////3v7NvcfNz9rs7d///v//7v7d2by8DAtwdwdwcAkADNvc3NzKe30ABwAAAAAHe5ncy83d7d3u7u7t/e3N3d3d793v
////7+///////u//7/7+//7+3eze3v3t3e3e/e2czK7MrHnJoAALAABwAHCpu7CXAABwAAB6x5easAl3enrN3d7t7e3d6e3u/v797e7v7u//////////////
/////v/+/+/v7t7u3t/u3dy9zOzdzAnLrMunCgAAe6yaCQB6oAAAAAAJrLm5C5uZy5Csy8e8rJ3N7u3t7u797u/////u//7+/////////////////+7u/u3e
zczdvNzd3dvNy6y7enCXqgkHkAAAAAcHAAd5vMuZqarMzbupnbmszd3d3d3ezt7v7/3u7v7u///+/u7u7f/u7v7u3t7v/u/t7e7dzd3d3N3d3d3d3czLzNrM
3dy7upqrucy7y7zKvMzdzNzMy8zMy8vNzd3d3c3N3d7e3t3d3d3d3d3d3d3d7t7u3t3e7u7t3d3d7d7d3e3d3d3c3e3u7u3dzc3d3N3N3c3c3dzNzN3N3d3K
u8zNzc3N3d3dzM3czc3d3d3czd3d3czc3d3d3d3t3dzd3d3d3d3e3d3d3N3d3d3d3d3d3d3d3dzdzd3d3N3d3d3d3d3d3d3d3dzd3d3N3d3d3d3c3d3d3d3d
3d3dzN3d3d3czd3d3d3d3d3d3d3d3c3dzd3d3d3d3d3d3d3d3t3d3dzd3d3d3d3c3d3d3d3d3d3d3d3d3d3d3d3d3N3d3d3d3d3d3d3d3d3d3d3N3N3d3d3d
3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3dzdy9/6DvDuDw+urq8PD7rw7w/g/w35D/AP8A/9Cv/A
r/6Qz/7J3u3KfO7tynre/+3KrN7/7dy7zd7+7ty7vN3e7u3dy7vM3d7u7t3cy7u8zd3e7u7d3czMzMzM3d3e7u7t3d3dzMzLzMzMzd3d3u7u7u7t3d3d3MzM
zMzMzd3d3d3dzN7svevdvr7Nzc6+vszr3r7b7r3svuu+677tvO7Lzu3Lzu3M3u3cvN7d3Lzd7t3MzN3u3dzMzd3u3d3MzN3d7d3dzMzN3d3d3d3czMzM3d3d
3d3d3d3MzMzd3d3d3d3d3d3d3czMzMzN3d3d3d3d3d3d3d3d3d3czMzd3d3d3d3Q/f/w/f994AAAAAAAAAzO7/////////////7bcAAAAAAAAAAAAAAACs3v
/////////////////+7cpwAAAAAAAAAAAAAAAAAAAAmbzd3d7u7///////////////////////7u7d3MypmQAAAAAAAAAAAAAAAAAAAHeavM3d7u7u//////
///////////////v7u7u3t7e3N3czczMu8qqqqmQcHAAAAAAAAAAB3mazM3d3u7u7u7u7v7+7+/u7u7u7u7u7t7d7u3e3d3d3d3MzN3N3c3d3d3e3t7t3d3d
3d3d3d/+sADQ///+3+DQ3QBwucrfzf///9AACnB3v////97KALyt7ccJ3v3/z//9cADrd9rs///szc2+2gAA3uy77////+2wAAAN/+7N/+7dzADN3begy97+
3//+29mwcAvdre///v7c0K3cwHCt3d3v7//+6pcAB63v/u7/3dy83d7JypcM7//92t7d3dmXCX3O7e///d3HAKDe3N3e//zd3d3u3HAJfN///3q/3Xvf7crL
fN3crt/97+/KcMzHrd3e3+3f/d7Zy6DcnM7+3v/+7tAAAMz//t3e7e+5AK3u7tAO7d3M7/7dztoACt///7v+/sqrmgCnve///93u7sugcJzNze/+797ewK3K
qt7s3s3+7b3/ywkAfe/73u7e3tybAH3u/c3e7/3JvdoAzNzc7f//26vHnMvJ3dz//t/+7HzJq5qazd7//+zMkAAL283u7e7u7N23vare/3Cd7//8nNzHAN3v
/t3d3N7drLzczu7t3Nzd7u3c3JzM3d3u7e3cvcvN3tzN7czd3tzM7+3Mzdq93u7dy7zd3czd7u3MvM3c3e3uy979ed7d3N7su8ze7d3e7czcu6vO7u3d3czc
3d283u3Lve3N3e7d3dzNy8ze3u7dzM3czd3c3N3ey83d3d7t3LrM3d3e3czd3dvMzd3t3MzN7c3czd3N3N3c3d3d3dzM3d3dy97u3czN3d7t3Mzd3dzN3d3d
3dzM3d3c3d3d3dzN3d3u3cvM3e3czd3d3dzN3c3N3d3d3d3d3d3cy83d3d3d3d3N3d3c3c3d3d3dzd3d3d3d3dzM3d7dzN3dzd3c3d3d3N3d3N3d3d3M3c3d
3d3d3d3dzd3d3d3dzN3d3dzd3d3d3c3d3d3d3d3d3d3d3d3d3c3d3d3d3t3d3d3d3d3d3d3d3d3dzN3d3dzN3d3d3d3d3d3dzd3d3d3d3d3d3d3d3d3czN3d
3dzN3d3d3d3d3d3d3d3d3d3d3d3d3d3c3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3czd3d3d3d3d3d3d3d
3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3c
eQB83u///+/w////2gAAAAAAAAAAAKzv/////////////////rAAAAAAAAAAAAAAAAAAAAq87v/////////////////////+7t3dy5dwAAAAAAAAAAAAAAAA
Bwm7zM3d3d3e7u7v7u7u7u3d3d3d3d3t7u7u7v7//+////7u7u3d3c3N3d3dp97/7w//8MAAAAAKCc3///////7QcAAAAAAAAP7////////93HAAAAAACc7P
/v///////tp3AAAAAAAMD6//7//////M0AAAAAALDA/v//////7/7dsAkAAAANAM3v/+7//73+DdAOnQD5Bw6Qv/7v/+/e3s7t7N8A7ACtD67d+r/d39/r33
3879cN/+yrrpnZfenP+d/u7P/f2t2t/dkKq7un3eff1/zO3v/e3s7t3fra2ce6DN3dy+7v3u38z/6q63mdrAAL3N7t7t/t/v/urcDdzAvAyc3J7M7d7d357e
z93M/c3b3Jvnrc6927zt397d/t/f3O3czskMvdkLvb3a/s7v/u7v25zu7Q3anXvN0N3czfv+3v3+7d7n3ay8rdq5rcnL3c3u/e//38/d69rQrbyr29DN3N3d
3d////CwANDu//0AAAAJ2///////8AAAAAB37//////3AAAAAAB9///////toAAAAAAM///////+kAAAAAAAvO/v/////+xwAAAAAAzv///////9kAAAAAAA
zv//////79kAAAAACpr+///////9kAAAAAAAvf////////wAAAAAAA3e//////7toAAAAAAACd3v///u7t/e7d3LyQAACQvN7v7+7u3u/+3csAAAAAAM7v//
////7dyQAAAAAACt7//////+7LAAAAAAAJu97//////u7LpwcAAAesy8vc3u/u3u7e7u7akAAAAACr3e7///////3dmgAAAAAJrN7//////t17qZyrqal8qr
y83d3u7u7t3N3dzbq6qqybzMyrzd7v///u7tzc26AAAAeszu/v/////t3cp3AAAAAAmt3f/////t2ZcAAAkLze7v////7coAAAAJze7/7u7u7+/93JAAAAAH
ze//////7dcAAAAACr3u////7+3cmQAAAKvd7v////7dynAAAAB6zd//////7cmQAAAJCpvt3t7e3s7N3LnAuczN7d7e3c3d7e7dywmanN3e/v7czLe3vMzM
zd7e7/7e3MuaAAAAB6zN7////v7dy3AAAAAMzd7//////euwAAAAAKze/////93bpwAHe6zN3c3d3d3t3cy5uam6zMzd7v7u7u3cyZcHmbzd3u7u7u7t3byq
qamszd3e7d3d3czMy7u7y7zM3d3d3d3d3c3d3N3d3d3d3dzc3MzM3d3d3d3d3d3dzMzMzMzNzM3d3czMzdzczMzMzMzMzMzM3d3d3u7e3d3dzMy7uru8zN3d
7d7u7t3d3My7qpqaq7zM3d3d7u3d3czLupmarMzd3u7u7u7t3d3Muqm6u8zM3d3d3d3d3dzMy7urrd3d3d3KlwB3m93v//////7ckAAAAAAAq97/////////
7ctwAAAAAAAArN7//////////+7ckAAAAAAAAAB6ze7///////////7d3d3d3eq+3Hrf2p7b3dvc3tvN3c3d3dzd2/187snuDu0N6u3crezdzN3M3tzd3d3c
3rzd3uqu/qr9ff7J7rztvdzN7czt3d3d3gAAAAAAnN7//////////doAAAAAAAAAAAB73v/////////////+3d3d3tzszO3d7t3d/ezZ7t7O3szs++3N3d3e
3O3t7u7e3t3d7NvN3d3e3dzt3d3d3N3e3d3dzt7N3M3t3t3e3d7d3d3d3d7t3t7d3d3d3dkN///9upcHBwzv///+/u/97tkHBwcHB87////////uvJd3cHBw
rN////////7t3JkHBwcHB87v/////u7cyXcHB3rMze7v//////7t7bt5eXd3d6zu/////93Mq7oHCXd5rN7e7u/+/u3e3cypB5mZqs3d7v///+3dzMu8ysmr
y83u7/7u7d3e7t3MuqqqvN3u7d3d3u/u7czKq6rMzM3d3e3e7e7t3dzc3MzMzNzN3NzN3d7u7u7d3czMzMzMzN3e7u7u7d3d3czMzMzM3d3d3d3e7e7u3d3M
zMvMzN3d3e7t3d3d3d3d3czMzN3d3d3d3d3d7t3d3d3d3d3s7u7v////7syXAAAACave7+7////+7tu8zMzOzbze7tzMu6u8zN3Lys3v/////u3d3cu7zczM
zMqrzMze7u/u3t7u7v/u7dy5AAAHms3d3u7u3LrM7////u7t3d3e7u3d3Mu5dwes3v//7u3u7t3d3d3d3M7N+dzNyqvO3v7u3c7MzcvK3Ozt3t3dzd7c2cyc
vc7e3szK3Nzt3dzMza283N3dzc3Nzc3M3d7d3d3dzd3MzMrA6X8PzfDwoAAJ////////4AAAAAAN//////+gAAAACv7/////8AAAAADA///////wAAAAALDf
r+///++gAAAAAADg/O//7+/74AAAAAAAzX8Pv+//7+7wwAAAAADA8PD5/d/fz9//fw8LBw0PD73a9/f8/u3t++3s650KCQeg3d3d3d3d3N3e3f7t3q+d7Aza
DQrffe+v///v/t73vacABwAAAAAHfQ/f///////////+zKcAAAAAAAAAAAB87v/////////////////t3Ll3AHAAAAAAmgAAAAAAAAAAAAAAB5m83u7/////
/////////////uysoAAAAAAAAAAHAJlwcAAAAAAAAAAAAAAJq8zd3d3d3d3d3d7//wqt0ADu7u3v/3AAxwB+9wqQesvf/////c3//a/aAJAA39/v///wd6nA
DLyQ2e/v///+2cqXAAe+/u/+3M3bzf/vzbCgAADQ7+//7doHrHre/a3rqZmt//3sygAACs7//+3s7e3f7v7czXAHzP////7Nqq3Nvczd3NzN39//3qx5d8mr
3d28zZzK7s7d3dqgeZyu7//+2d3ZzLze7e7u65zN3e693d2+3t7u/ty8nNy83v7e3szLzd3u3d3d3d3d3d3e7urM3aqu7u7d7uuqrKqr7qrLq8zN7u7u7tze
7tztyquqre3u7u7uqqy8qszLrb3t7u7u7bzLqqq83t7u7czdzN7t7Nysqqqtru7u7d3KrMrN7tzezLu83u7e3Mqqqszu7u7e3d7d7u7d3dqqvd7u7u7s3Mzd
3Nzd3c3N3e3u7ezaur28zd3czNvMve3t3d28qrvM7u7u7b3dvczd3d7d3cvM3d3c3d3c3e3e7t3M283Mze7t3dzMzN3e7d3d3d3d3d3d7u68zdu83d3d3u7L
u9y7zey8y8zc3u7u7u3d7u3O3LvLvN7e3u7u68zMy73NzNze3u7u7dzczLu8ze3e7d3N3M3u3s3My7vL297e7t3cvM3M3e3N3MzMze7t3dy7u7zN7u7d3d3d
3t3t3d3MzN3u7u7tzczN3c3d3dzd3d7e7t3NzMzczN3dzd3N3N3d3d3czMzMzd7u7dzd3N3N3d3d3dzNzd3dzd3dzd3d3e3dzczdzd3t3d3c3M3d3d3d3d3d
3u7t6v0Av///AAAA////AAAA//+3AAz8//6/7bsAAArO////8AAHDd5wAACf/////sAAAAAAAADd//////7+4AAAD/0ADf///+zQDMna//7AAADf/8AAAAAP
/////////6yQAAcAAAAP////3Mz//QAAAAze///////buQCgvu6QAAD/////7aAAB+///Pvc3v///evMx3zKkABwvbnezN3t7/16ve7/7////928vJCqndnN
zcfs//+5AAAADN7f3bub7////d3d3d3d3u3eztqs7u7qqqqu7u7qqqqu7uyqqt7O7tzu3Mqqqrzu7u7uqqq63dqqqqvu7u7u3Kqqqqqqqq3e7u7u7u7uqqqq
7tqq3u7u7s2qzb3O7u2qqq3u7Kqqqqru7u7u7u7u7Muqqrqqqqru7u7t3M7u2qqqqs3u7u7u7u3Muqus7tuqqq7u7u7u3Kqqre7uzs3N3u7u3s3duszLqqqs
3L3szd7e7trM3d7u7u7u7dzcy6u73bzc3L3O7uy6qqqqzd3t3MvO7u7u3d3d3d3d3d3c7czd7u7MzMzu7u7MzMzu7szMzd3u7c7d3MzMzN3u7u7szMzN3czM
zM7u7u7t3MzMzMzMzN3u7u7u7e3czMzN7czN7u7u3dzN3Nze7dzMzN7u3MzMzM3u7u7u7u7uzczMzMzMzM7u7u7d3e3tzMzMzd3u7u7u7tzMzMzN3czMzO7u
7u7dzMzM3e3t3N3d7u7t3N3czdzMzMzN3N3d3d3e7czN3d3e7u7u3c3NzMzN3N3d3N3e7czMzMzN3d7dzMzd7u7d3d3d3d3d/e7u797e3dynDHDw0AAHmrvM
wAAAnf////////////////////wAAAAAAAAAAAAAAAAAAAAAmrzN3d3t7t7t3v/////////////////////////+7bkAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAe83v////////////////////7dy6cAAAAAAAd5q8zN3d3d3d3d3d3d3d3d3eygn//9AAAK////+pAM7QAAC9///////cAAAAAADN////////3A
BwAAAAAM7/////7uq9wAoAAMvezv/+3u/b0LvJ2gCc/d/u7unN7+3O3vAK3Azw36Dfyf/d/Q3/AMfvzdAN4M8J/+3d/+zqDpp+xw0L/P/c3/7b3Q6+6wDQDu
2+/ezO3+/M7Nnb3cD9nLq9ze/vx73P7uzf7M3aeZ3e3N3N7+3v3P3ty6zNCwuc3N7u7/797d3Amq3t3c3A3d7+z+393d3d3e3e7ens3p8PnfD8ra6fDw68zM
nNwOfsn6/v//////7+3c5+DZoJAAAAAAAAAAAHvMze3//////////////////vzsepBwAAAAAAAAAAAAAAAAAAeau9zt7//////////////////////u3cy3
cAAAAAAAAAAAAAAAAAAAAAd6rN3e/////////////////////////+7u3d3d3d3d3d3aC9/+8P//DAcHAACgDc////////4JAAAAAAAHAP/////////8sAAA
AAAAet7/////////7bkAAAAAAAAK3v///////v7XsAAAAAAAru7////////+7ntwAJAAAJ297////f//vf2c6gqucOt3zdDe/v7t3u3f7e39zXDaDdsN3cvt
ns7O3u/P3v7uzdzey5qct9nd3u3s3t/t7//bza3twM2cuuzN3M7M7d3N/97d3c7t7NzQ2qyszd3c3+7d7e7O7cvdu62rq83c7dzN7u3d7d7d2+7Nvdzb3Mzc
3Nzd3d3d7t3Myf/QDf///ADe/woAAN///////nAAAAAAAO/////////AAAAAAACv/////////+zAAAAAAAAAAAve///////////+sAAAAAAAAAAAr///////
///u7///////7ccAAAAAAAAJzM3d7////u7v/////////+y5AAAAAAAAAAAAe7zd3v/////////////+3buXl6qXkAAAAAAAAAAACs3d3d3dsAAAAK3v7/7/
///smwAAAAzJ3/7v////7cyQAAAADQutrP///9uQAAuuwAff///////KsAAAAAAJyt3v/////9AMqnCQAAnu/v797u2geQAPzH3dv+///97+d92d0AAAAJAN
3f/////9fHC7ANCbvf///879rwzpDQzdDZ2+3v/t3evtzp+8ybCg3K/P7/3//+6skADQ18ve3////u7cDMvcrZzLft/+/97ezpsLnJ2r393v397u/e7s27zc
6q2cDczd///f3+y9CcvJ2uy/z+7+7NmtvczNy97e7t3al9fNzu7v7/7drAzMytzbrt3u793dzbzLzM3czczP3+3s3MzNze/O383r3d3c7e7d7ezezN3NzM7N
3v7szMzNy92t3M7e3/7u3cu8y8zdze3e3u7e3tzNmcvOze3d3u3dzd3t3c3d3d3d0A==
"""

    /// The samples, one to a byte.
    static func samples() -> [UInt8] {
        Base64.decode(packed).flatMap { [$0 >> 4, $0 & 15] }
    }
}
