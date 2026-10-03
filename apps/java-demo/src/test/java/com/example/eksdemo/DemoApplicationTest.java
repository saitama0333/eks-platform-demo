package com.example.eksdemo;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class DemoApplicationTest {
    @Test
    void greetingNamesTheJavaDemo() {
        assertEquals("Hello from the Java Maven EKS demo", DemoApplication.greeting());
    }
}
