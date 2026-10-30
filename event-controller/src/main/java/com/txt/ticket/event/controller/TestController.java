package com.txt.ticket.event.controller;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class TestController {

    @GetMapping("/test")
    public String helloWord() {
        return "Test Deploy";
    }
}
