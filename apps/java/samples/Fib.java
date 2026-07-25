public class Fib {
    public static void main(String[] args) throws Exception {
        int a = 0, b = 1;
        for (int i = 1; i <= 30; i++) {
            System.out.println(b);
            int t = a + b;
            a = b;
            b = t;
        }
    }
}
