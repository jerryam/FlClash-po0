package com.follow.clash.service.modules

import android.app.Service
import com.follow.clash.service.po0.Po0Firewall

internal class Po0Module(private val service: Service) : ServiceModule {
    override fun start() = Po0Firewall.attachService(service)

    override fun stop() = Po0Firewall.detachService(service)
}
