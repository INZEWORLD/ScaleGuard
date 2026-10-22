package com.follow.clashx.service;

interface IResultInterface {
    oneway void onResult(in long runTime);
    /** Reason a start was refused, sent before the failing [onResult]. */
    oneway void onError(in String message);
}
